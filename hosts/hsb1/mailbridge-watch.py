#!/usr/bin/env python3
"""OPS-196: observe the residue bridge without moving or reading any mail.

Only fixed error categories, counts and timestamps leave this process. In
particular, never log an exception, OAuth response, IMAP response or config.
The independent tailnet witness watches this poller's snapshot freshness.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import imaplib
import json
import re
import ssl
import subprocess
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import engine
from engine import Problem

CONFIG = "@CONFIG@"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
DOCKER = "@DOCKER@"
CA_BUNDLE = "@CA_BUNDLE@"
GRANT_ISSUED_AT = "@GRANT_ISSUED_AT@"
STATE_DIR = Path("/var/lib/mailbridge-watch")
STALL_SECONDS = 2 * 60 * 60
MAX_BYTES = 1024 * 1024


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("invalid state")
    return value


def load_config() -> dict:
    with open(CONFIG, "rb") as handle:
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("oversized config")
    cfg = tomllib.loads(raw.decode())
    client = json.loads(cfg["Secrets"])["installed"]
    tokens = json.loads(cfg["Tokens"])
    for value in (client["client_id"], client["client_secret"], tokens["refresh_token"]):
        if not isinstance(value, str) or not value:
            raise ValueError("missing credential")
    accounts = cfg["Imap"]
    if not isinstance(accounts, list) or not 1 <= len(accounts) <= 4:
        raise ValueError("invalid accounts")
    total = 0
    for account in accounts:
        # This monitor has one supported source/provider; never follow a host or
        # token_uri from a secret to an arbitrary credential destination.
        if account["Address"] != "mail.hover.com:993":
            raise ValueError("unsupported provider")
        for field in ("Username", "Password"):
            if not isinstance(account[field], str) or not account[field]:
                raise ValueError("missing credential")
        folders = mapped_folders(account)
        total += len(folders)
        for folder in folders:
            if not folder or re.search(r"[\x00-\x1f\x7f]", folder):
                raise ValueError("invalid folder")
    if total > 12:
        raise ValueError("too many folders")
    return {"client": client, "tokens": tokens, "accounts": accounts}


def mapped_folders(account: dict) -> dict[str, bool]:
    """Map every source and configured failure destination; True = failure box."""
    sources = account.get("Folders") or {"INBOX": ["INBOX"], "Junk": ["SPAM"]}
    failed = account.get("FailedFolders") or {}
    if not isinstance(sources, dict) or not isinstance(failed, dict):
        raise ValueError("invalid mapping")
    folders = {name: False for name in sources}
    for source in sources:
        destination = failed.get(source, failed.get("*"))
        if destination:
            if destination in sources:
                raise ValueError("failure folder also a source")
            folders[destination] = True
    if not all(isinstance(name, str) for name in folders):
        raise ValueError("invalid mapping")
    return folders


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def oauth_probe(cfg: dict) -> str:
    """Refresh in memory only; do not share or persist the returned access token."""
    form = {
        "grant_type": "refresh_token",
        "client_id": cfg["client"]["client_id"],
        "client_secret": cfg["client"]["client_secret"],
        "refresh_token": cfg["tokens"]["refresh_token"],
    }
    request = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(form).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    opener = urllib.request.build_opener(
        NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=CA_BUNDLE)),
    )
    try:
        with opener.open(request, timeout=15) as response:
            result = json.loads(response.read(65537))
        if (
            not isinstance(result, dict)
            or not isinstance(result.get("access_token"), str)
            or not result["access_token"]
            or result.get("token_type", "").lower() != "bearer"
            or not isinstance(result.get("expires_in"), (int, float))
            or result["expires_in"] <= 0
        ):
            return "invalid_response"
        if result.get("refresh_token", form["refresh_token"]) != form["refresh_token"]:
            return "credential_rotation_required"
        return "ok"
    except urllib.error.HTTPError as error:
        try:
            if error.code == 429 or error.code >= 500:
                return "transient_http"
            try:
                category = json.loads(error.read(65537)).get("error")
            except Exception:
                category = None
        finally:
            error.close()
        if category in ("invalid_grant", "invalid_client", "unauthorized_client"):
            return category
        return "http_error"
    except Exception:
        return "transport_or_response_error"


def mailbox_counts(cfg: dict) -> tuple[str, dict]:
    counts = {}
    mapping = []
    for index, account in enumerate(cfg["accounts"]):
        folders = sorted(mapped_folders(account).items())
        mapping.append([account["Username"], folders])
        for folder_index, (_, failed) in enumerate(folders):
            counts[f"a{index}f{folder_index}"] = {"count": None, "failed_folder": failed}
        client = None
        try:
            client = imaplib.IMAP4_SSL(
                "mail.hover.com", 993,
                ssl_context=ssl.create_default_context(cafile=CA_BUNDLE), timeout=8,
            )
            client.login(account["Username"], account["Password"])
            for folder_index, (folder, _) in enumerate(folders):
                quoted = '"' + folder.replace("\\", "\\\\").replace('"', '\\"') + '"'
                try:
                    result, data = client.status(quoted, "(MESSAGES)")
                    if result != "OK" or not data or not isinstance(data[0], bytes):
                        continue
                    match = re.search(rb"\bMESSAGES\s+(\d+)\b", data[0])
                    if match:
                        counts[f"a{index}f{folder_index}"]["count"] = int(match[1])
                except Exception:
                    # One unknown folder must not blind all other queues.
                    pass
        except Exception:
            # Unobserved folders remain explicitly unknown, never zero.
            pass
        finally:
            if client is not None:
                try:
                    client.logout()
                except Exception:
                    pass
    fingerprint = hashlib.sha256(json.dumps(mapping, sort_keys=True).encode()).hexdigest()
    return fingerprint, counts


def bridge_probe() -> dict:
    try:
        running = subprocess.run(
            [DOCKER, "ps", "--filter", "name=^/turbogmailify$", "--format", "{{.State}}"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip() == "running"
        if not running:
            return {"state": "not_running", "import_errors": 0}
        logs = subprocess.run(
            [DOCKER, "logs", "--since", "10m", "--tail", "2000", "turbogmailify"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        # Logs contain mail subjects; only an integer leaves this function.
        errors = sum("Error importing message:" in line for line in (logs.stdout + logs.stderr).splitlines())
        return {"state": "running", "import_errors": errors}
    except Exception:
        return {"state": "unknown", "import_errors": 0}


def queue_problems(current: dict, prior: dict, stamp: float) -> tuple[dict, list[Problem]]:
    saved = {}
    problems = []
    for key, item in current.items():
        count = item["count"]
        old = prior.get(key, {})
        old_count = old.get("count")
        since = old.get("since", stamp)
        observed = count is not None
        if not observed:
            problems.append(Problem(f"mailbridge:imap:{key}", f"hsb1: configured mail folder {key} cannot be observed."))
            count = old_count  # retain known residue and its clock during outage
        if not isinstance(since, (float, int)) or since > stamp or not old_count:
            since = stamp
        if observed and (count == 0 or not old_count or count < old_count):
            since = stamp
        saved[key] = {**item, "count": count, "since": since, "observed": observed}
        if count and item["failed_folder"]:
            problems.append(Problem(f"mailbridge:failed:{key}", "hsb1: residue remains in a configured Failed folder."))
        elif count and stamp - since >= STALL_SECONDS:
            problems.append(Problem(f"mailbridge:queue:{key}", "hsb1: a source queue has not observably decreased for two hours; inspect import progress."))
    return saved, problems


def observe(stamp: float, previous: dict) -> tuple[dict, list[Problem]]:
    snapshot = {"checked_at": stamp, "complete": False, "auth": "unknown", "queue": {}}
    problems = []
    try:
        cfg = load_config()
    except Exception:
        return snapshot, [Problem("mailbridge:config", "hsb1: mailbridge configuration is unreadable or invalid.")]
    snapshot["auth"] = oauth_probe(cfg)
    if snapshot["auth"] != "ok":
        problems.append(Problem(f"mailbridge:oauth:{snapshot['auth']}", f"hsb1: Gmail authorization check failed ({snapshot['auth']}); no automated restart or re-consent."))
    snapshot["bridge"] = bridge_probe()
    if snapshot["bridge"]["state"] != "running":
        problems.append(Problem("mailbridge:bridge", "hsb1: residue bridge is stopped or its state is unknown."))
    if snapshot["bridge"]["import_errors"]:
        problems.append(Problem("mailbridge:imports", "hsb1: recent Gmail import failures; running container does not prove mail delivery."))
    try:
        fingerprint, counts = mailbox_counts(cfg)
        prior = previous.get("queue", {}) if previous.get("mapping") == fingerprint else {}
        snapshot["queue"], queue_issues = queue_problems(counts, prior, stamp)
        snapshot["mapping"] = fingerprint
        problems.extend(queue_issues)
        snapshot["complete"] = all(item["count"] is not None for item in counts.values())
    except Exception:
        # Preserve the last observation through an outage; an unreadable folder
        # must not reset the stall clock or clear a known retained-mail issue.
        if isinstance(previous.get("queue"), dict) and previous.get("mapping"):
            snapshot["mapping"] = previous["mapping"]
            snapshot["queue"], retained = queue_problems(previous["queue"], previous["queue"], stamp)
            problems.extend(retained)
        problems.append(Problem("mailbridge:imap", "hsb1: configured source/Failed folder counts are unknown."))
    try:
        issued = dt.datetime.fromisoformat(GRANT_ISSUED_AT.replace("Z", "+00:00"))
        if issued.tzinfo is None or not 0 < issued.timestamp() <= stamp:
            raise ValueError("invalid issuance")
        snapshot["grant_issued_at"] = issued.timestamp()
    except ValueError:
        problems.append(Problem("mailbridge:publication", "hsb1: production OAuth grant issuance is not recorded; durable recovery is unverified."))
    issued_at = snapshot.get("grant_issued_at")
    recorded = previous.get("day8_verified_at")
    snapshot["day8_verified_at"] = None
    if (issued_at and previous.get("grant_issued_at") == issued_at
            and isinstance(recorded, (int, float))
            and issued_at + 8 * 86400 <= recorded <= stamp):
        snapshot["day8_verified_at"] = recorded
    snapshot["day8_check_ok"] = bool(
        not problems and issued_at and stamp - issued_at >= 8 * 86400
        and all(item["count"] == 0 for item in snapshot["queue"].values())
    )
    if snapshot["day8_check_ok"] and snapshot["day8_verified_at"] is None:
        snapshot["day8_verified_at"] = stamp
    return snapshot, problems


def render(announced: list[str], cleared: list[str]) -> str:
    lines = ["Mail bridge (hsb1 / OPS-196)"]
    if announced:
        lines += ["Problems:", *announced]
    if cleared:
        lines += ["Cleared:", *cleared]
    return "\n".join(lines)


def main() -> int:
    stamp = time.time()
    path = STATE_DIR / "status.json"
    state_problem = []
    try:
        previous = read_json(path)
    except FileNotFoundError:
        previous = {}
    except Exception:
        previous = {}
        state_problem = [Problem("mailbridge:state", "hsb1: prior monitor snapshot is invalid; queue history is unknown.")]
    snapshot, problems = observe(stamp, previous)
    problems += state_problem
    snapshot["problem_count"] = len(problems)
    snapshot["delivery"] = "pending"
    engine.atomic_write_state(str(path), snapshot)
    try:
        target = engine.env_file_value(NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL")
        sender = engine.shoutrrr_telegram_sender(target)
        result = engine.run_cycle(str(STATE_DIR / "alerts.json"), stamp, lambda: problems, render, sender)
    except Exception:
        # Never echo exceptions: transport/config errors can include secrets.
        result = engine.EXIT_UNDELIVERED
    snapshot["delivery"] = "failed" if result == engine.EXIT_UNDELIVERED else "ok"
    if result == engine.EXIT_UNDELIVERED and snapshot.get("day8_verified_at") == stamp:
        snapshot["day8_verified_at"] = None
    engine.atomic_write_state(str(path), snapshot)
    print(f"mailbridge: problems={len(problems)}, delivery={snapshot['delivery']}")
    return result


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print("mailbridge: monitor failed; inspect service state, never dump credentials")
        raise SystemExit(3) from None
