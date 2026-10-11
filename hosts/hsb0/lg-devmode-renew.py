#!/usr/bin/env python3
"""OPS-309: bounded renewal, calendar-day streaks and existing alert transports."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import stat
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import engine
from notification_delivery import email_sender, private_config

BACKOFF = (60, 300, 900)
TIMEOUT = 20
MAX_RESPONSE = 16384
ORIGIN = "https://developer.lge.com/secure/"
CHANNELS = {"email", "telegram"}
RECOVERY_RETRIES = 3  # One initial attempt, then at most three later retries.
MISSING_CREDENTIAL_EXIT = 3
TEST_ALERT = "[TEST] LG Developer Mode renew alert path check"
Sender = Callable[[str, str], bool]


@dataclass(frozen=True)
class Outcome:
    success: bool
    reason: str
    http: str = "unavailable"
    code: str = "unavailable"
    remaining: str = "unavailable"


def read_token(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_mode & 0o077 or metadata.st_nlink != 1
                or metadata.st_size > 256):
            raise ValueError("credential custody refused")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            match = re.fullmatch(rb"LG_DEVMODE_TOKEN=([0-9a-fA-F]{64})\r?\n?", handle.read(257))
        if match is None:
            raise ValueError("credential format refused")
        return match[1].decode("ascii")
    finally:
        os.close(descriptor)


def request(token: str, renew: bool, curl: str) -> Outcome:
    endpoint = "ResetDevModeSession.dev" if renew else "CheckDevModeSession.dev"
    # No redirects, user curlrc, URL argv, inherited token environment or body logs.
    command = [curl, "--disable", "--silent", "--proto", "=https",
               "--max-time", str(TIMEOUT), "--connect-timeout", "10",
               "--max-filesize", str(MAX_RESPONSE), "--write-out", "\n%{http_code}",
               "--config", "-"]
    try:
        reply = subprocess.run(
            command, input=f'url = "{ORIGIN}{endpoint}?sessionToken={token}"\n'.encode(),
            capture_output=True, timeout=TIMEOUT, check=False,
        )
    except subprocess.TimeoutExpired:
        return Outcome(False, "timeout")
    except OSError:
        return Outcome(False, "network")
    if reply.returncode:
        return Outcome(False, "timeout" if reply.returncode == 28 else "network")
    body, _, status = reply.stdout.rpartition(b"\n")
    http = status.decode("ascii") if re.fullmatch(rb"[1-5][0-9]{2}", status) else "unavailable"
    if len(body) > MAX_RESPONSE:
        return Outcome(False, "response-too-large", http)
    try:
        document = json.loads(body)
    except (ValueError, UnicodeError):
        return Outcome(False, "invalid-json", http)
    if not isinstance(document, dict):
        return Outcome(False, "invalid-json", http)
    raw_code = document.get("errorCode")
    code = str(raw_code) if type(raw_code) in (int, str) else ""
    code = code if re.fullmatch(r"[0-9]{1,6}", code) else "unavailable"
    if http != "200":
        return Outcome(False, "http", http, code)
    if document.get("result") != "success" or code != "200":
        return Outcome(False, "lg-error", http, code)
    # Check reports HHH:MM:SS in errorMsg. Never echo arbitrary server text.
    remaining = document.get("errorMsg")
    remaining = (remaining if isinstance(remaining, str)
                 and re.fullmatch(r"[0-9]{1,4}:[0-5][0-9]:[0-5][0-9]", remaining)
                 else "unavailable")
    return Outcome(True, "success", http, code, remaining)


def log_result(action: str, outcome: Outcome) -> None:
    print(f"lg-devmode-renew: {action} {'success' if outcome.success else 'failed'} "
          f"reason={outcome.reason} HTTP={outcome.http} LG_errorCode={outcome.code}")


def fresh_state() -> dict:
    return {"schema_version": 1, "last_success_time": None, "last_failed_day": None,
            "consecutive_failed_days": 0, "streak_id": None,
            "failure_notified": [], "recoveries": []}


def load_state(path: Path) -> dict:
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return fresh_state()
    if len(raw) > 65536:
        raise ValueError("state too large")
    state = json.loads(raw)
    if (not isinstance(state, dict) or set(state) != set(fresh_state())
            or state["schema_version"] != 1
            or type(state["consecutive_failed_days"]) is not int
            or state["consecutive_failed_days"] < 0
            or not isinstance(state["recoveries"], list)):
        raise ValueError("state schema refused")
    if state["last_failed_day"] is not None:
        dt.date.fromisoformat(state["last_failed_day"])
    if state["last_success_time"] is not None:
        dt.datetime.fromisoformat(state["last_success_time"])
    if state["streak_id"] is not None:
        uuid.UUID(state["streak_id"])
    validate_channels(state["failure_notified"])
    for pending in state["recoveries"]:
        if (not isinstance(pending, dict)
                or set(pending) not in ({"id", "channels"}, {"id", "channels", "attempts"})):
            raise ValueError("recovery state refused")
        uuid.UUID(pending["id"])
        validate_channels(pending["channels"])
        # Accept the previous schema's pending notices without losing them.
        attempts = pending.setdefault("attempts", dict.fromkeys(pending["channels"], 0))
        if (not isinstance(attempts, dict) or set(attempts) != set(pending["channels"])
                or any(type(n) is not int or not 0 <= n <= RECOVERY_RETRIES + 1
                       for n in attempts.values())):
            raise ValueError("recovery attempts refused")
    return state


def load_or_reset_state(path: Path) -> dict:
    try:
        return load_state(path)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError, OverflowError):
        # Notification bookkeeping must never prevent the HTTP renewal. Keep
        # the refused bytes for diagnosis without printing them or exceptions.
        quarantine = path.with_name(f"{path.name}.corrupt-{time.time_ns()}")
        try:
            path.rename(quarantine)
        except OSError:
            print("lg-devmode-renew: state-reset quarantine=unavailable")
        else:
            print("lg-devmode-renew: state-reset quarantine=accepted")
        return fresh_state()


def validate_channels(channels: list) -> None:
    if (not isinstance(channels, list) or any(type(c) is not str for c in channels)
            or not set(channels) <= CHANNELS or len(channels) != len(set(channels))):
        raise ValueError("notification state refused")


def save_state(path: Path, state: dict) -> None:
    engine.atomic_write_state(str(path), state)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def failure_message(days: int) -> str:
    return (f"LG beamer Developer Mode renew failing for {days} days — "
            "sideloaded apps will vanish when the session hits 0; check the token "
            "(changes if Developer Mode is reinstalled)")


def notify(path: Path, state: dict, senders: dict[str, Sender]) -> bool:
    delivered = True
    # Clear older recovery notices before announcing a later failure streak.
    # Bound notification time as well as retry count: one queued recovery per
    # run, plus the current failure notice, using the existing transports.
    for pending in state["recoveries"][:1]:
        for channel in pending["channels"][:]:
            sender = senders.get(channel)
            attempts = pending["attempts"][channel]
            if sender is None or attempts >= RECOVERY_RETRIES + 1:
                pending["channels"].remove(channel)
                del pending["attempts"][channel]
                save_state(path, state)
                reason = "no-existing-transport" if sender is None else "retry-limit"
                print(f"lg-devmode-renew: recovery notification dropped channel={channel} reason={reason}")
                continue
            # Persist before delivery so interrupted sends also consume a try.
            pending["attempts"][channel] = attempts + 1
            save_state(path, state)
            if sender("LG beamer Developer Mode renew recovered — session renewed successfully.",
                      f"lgdevmode-{pending['id']}-recovery"):
                pending["channels"].remove(channel)
                del pending["attempts"][channel]
                save_state(path, state)
                print(f"lg-devmode-renew: recovery notification accepted channel={channel}")
            elif pending["attempts"][channel] >= RECOVERY_RETRIES + 1:
                pending["channels"].remove(channel)
                del pending["attempts"][channel]
                save_state(path, state)
                print(f"lg-devmode-renew: recovery notification dropped channel={channel} reason=retry-limit")
            else:
                delivered = False
                print(f"lg-devmode-renew: recovery notification pending channel={channel}")
        if not pending["channels"]:
            state["recoveries"].remove(pending)
            save_state(path, state)
    if state["consecutive_failed_days"] >= 2:
        if not senders:
            print("lg-devmode-renew: failure notification unavailable: no existing transport")
            return False
        for channel, sender in senders.items():
            if channel in state["failure_notified"]:
                continue
            if sender(failure_message(state["consecutive_failed_days"]),
                      f"lgdevmode-{state['streak_id']}-failure"):
                state["failure_notified"].append(channel)
                save_state(path, state)
                print(f"lg-devmode-renew: failure notification accepted channel={channel}")
            else:
                delivered = False
                print(f"lg-devmode-renew: failure notification pending channel={channel}")
    return delivered and not state["recoveries"]


def run_cycle(token_path: Path, state_path: Path, curl: str, senders: dict[str, Sender],
              sleep: Callable[[float], None] = time.sleep,
              clock: Callable[[], dt.datetime] = lambda: dt.datetime.now().astimezone()) -> int:
    state = load_or_reset_state(state_path)
    try:
        token = read_token(token_path)
    except FileNotFoundError:
        token = None
        outcome = Outcome(False, "credential-missing")
        log_result("renewal", outcome)
    except (OSError, ValueError):
        token = None
        outcome = Outcome(False, "credential-invalid")
        log_result("renewal", outcome)
    else:
        for attempt in range(len(BACKOFF) + 1):
            outcome = request(token, True, curl)
            log_result("renewal", outcome)
            if outcome.success:
                break
            if attempt < len(BACKOFF):
                print(f"lg-devmode-renew: retry in {BACKOFF[attempt]} seconds")
                sleep(BACKOFF[attempt])

    now = clock()
    if outcome.success:
        state["last_success_time"] = now.astimezone(dt.timezone.utc).isoformat()
        if state["failure_notified"]:
            state["recoveries"].append({"id": state["streak_id"],
                                        "channels": state["failure_notified"][:],
                                        "attempts": dict.fromkeys(state["failure_notified"], 0)})
        state.update(last_failed_day=None, consecutive_failed_days=0,
                     streak_id=None, failure_notified=[])
    else:
        today = now.date()
        previous = dt.date.fromisoformat(state["last_failed_day"]) if state["last_failed_day"] else None
        if previous is None or today > previous:
            state["consecutive_failed_days"] = (state["consecutive_failed_days"] + 1
                                                if previous == today - dt.timedelta(days=1) else 1)
            state["last_failed_day"] = today.isoformat()
        if state["streak_id"] is None:
            state["streak_id"] = str(uuid.uuid4())
    # Commit renewal state before the optional check or any alert attempt.
    save_state(state_path, state)
    print(f"lg-devmode-renew: consecutive_failed_days={state['consecutive_failed_days']}")
    if token is not None:
        check = request(token, False, curl)
        log_result("check", check)
        print(f"lg-devmode-renew: remaining_session_time={check.remaining}")
    else:
        print("lg-devmode-renew: remaining_session_time=unavailable")
    delivered = notify(state_path, state, senders)
    if outcome.reason == "credential-missing":
        return MISSING_CREDENTIAL_EXIT
    return 0 if outcome.success and delivered else 1


def existing_senders(credentials: Path, docker: str, *, test_notify: bool = False) -> dict[str, Sender]:
    senders = {}
    destinations = Path(os.environ.get("LG_DEVMODE_DESTINATIONS_FILE", credentials / "destinations.json"))
    if destinations.exists():
        try:
            config = private_config(str(destinations))
            senders["email"] = email_sender(config.get("email", {}), docker,
                                             subject=TEST_ALERT if test_notify else "LG beamer Developer Mode")
        except (OSError, ValueError, TypeError, AttributeError):
            print("lg-devmode-renew: email notification configuration unavailable")
    notification_env = Path(os.environ.get("LG_DEVMODE_NOTIFICATION_ENV_FILE", credentials / "notification-env"))
    if notification_env.exists():
        try:
            target = engine.env_file_value(str(notification_env), "WATCHTOWER_NOTIFICATION_URL")
            senders["telegram"] = engine.shoutrrr_telegram_sender(target)
        except (ValueError, TypeError):
            print("lg-devmode-renew: Telegram notification configuration unavailable")
    return senders


def test_notification(senders: dict[str, Sender]) -> int:
    if not senders:
        print("lg-devmode-renew: TEST notification unavailable: no existing transport")
        return 2
    # Exactly one alert; prefer email, the declared hsb0 path, even if a future
    # Telegram sender exists. No token, state access, renewal, or retry here.
    channel = "email" if "email" in senders else next(iter(senders))
    accepted = senders[channel](TEST_ALERT, f"lgdevmode-{uuid.uuid4()}-test")
    print(f"lg-devmode-renew: TEST notification {'accepted' if accepted else 'failed'} channel={channel}")
    return 0 if accepted else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--renew", action="store_true", help="explicitly renew and update durable state")
    modes.add_argument("--test-notify", action="store_true", help="send one TEST alert without token or state access")
    args = parser.parse_args()
    credentials = Path(os.environ.get("CREDENTIALS_DIRECTORY", "/nonexistent"))
    curl = os.environ.get("LG_DEVMODE_CURL", "curl")
    try:
        if args.test_notify:
            return test_notification(existing_senders(
                credentials, os.environ.get("LG_DEVMODE_DOCKER", "docker"), test_notify=True))
        token_path = Path(os.environ.get("LG_DEVMODE_TOKEN_FILE", credentials / "token"))
        if not args.renew:
            result = request(read_token(token_path), False, curl)
            log_result("check", result)
            print(f"lg-devmode-renew: remaining_session_time={result.remaining}")
            return 0 if result.success else 1
        missing_notification_credential = False
        for variable, kind in (("LG_DEVMODE_DESTINATIONS_FILE", "email-config"),
                               ("LG_DEVMODE_NOTIFICATION_ENV_FILE", "telegram-config")):
            if os.environ.get(variable) and not Path(os.environ[variable]).exists():
                missing_notification_credential = True
                print(f"lg-devmode-renew: failed reason=credential-missing kind={kind}")
        result = run_cycle(token_path,
                           Path(os.environ.get("STATE_DIRECTORY", "/var/lib/lg-devmode-renew")) / "state.json",
                           curl, existing_senders(credentials, os.environ.get("LG_DEVMODE_DOCKER", "docker")))
        return MISSING_CREDENTIAL_EXIT if missing_notification_credential else result
    except FileNotFoundError:
        print("lg-devmode-renew: failed reason=credential-missing")
        return 2 if args.test_notify else MISSING_CREDENTIAL_EXIT
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        # Exception text can contain credentials or a reflected response: never echo it.
        print("lg-devmode-renew: failed reason=credential-or-state-unavailable")
        return 2 if args.test_notify else 1


if __name__ == "__main__":
    raise SystemExit(main())
