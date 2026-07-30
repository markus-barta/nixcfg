#!/usr/bin/env python3
"""Shared alert-poller mechanics — OPS-107.

WHY THIS EXISTS
===============
Two alert pollers were built days apart by different sessions: hausv-alerts on
csb1 (NIX-332) and ops-alerts on csb0 (OPS-104). Both are a systemd timer running
a Python poller with persisted state, both alert on transitions, both talk to
Telegram. Together they were two copies of the same machinery -- and neither
noticed if the other died, which is the same silent-failure shape both were built
to eliminate.

This module is the shared half. It owns the MECHANICS only:

  * durable delivery      -- a write-ahead log, described below
  * atomic state writes   -- a crash mid-write must not corrupt state
  * confirm-before-alert  -- a single bad run must never page anyone
  * transition detection  -- announce a problem once, clear it once

It deliberately does NOT own presentation. hausv-alerts formats German,
product-specific text for HAUSV's operators; ops-alerts formats English fleet
text. Forcing those into one template would be a merge for its own sake, so each
consumer supplies its own check set and its own formatter.

THE DELIVERY WRITE-AHEAD LOG (adopted from hausv-alerts, NIX-332)
================================================================
The naive loop -- mark the problem announced, then send -- loses the alert
outright if the notification channel is down: state says "announced", nothing was
delivered, and nothing retries. The ops-alerts poller shipped with exactly that
bug. This is the fix:

    1. write state containing pending{event_id, text, next_state}
    2. attempt delivery
    3. ONLY on success, commit next_state (dropping pending)

A failed send leaves `pending` on disk and returns EXIT_UNDELIVERED, so the next
cycle re-sends the identical text before committing anything. An alert is
therefore never lost and never announced twice, and because the caller maps
EXIT_UNDELIVERED outside SuccessExitStatus, an undeliverable alert also surfaces
as a failed systemd unit.
"""

from __future__ import annotations

import json
import os
import ssl
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

EXIT_CLEAN = 0
EXIT_PROBLEMS = 1
EXIT_UNDELIVERED = 2

NETWORK_TIMEOUT_SECONDS = 15

# A problem must be seen on this many CONSECUTIVE runs before it is announced.
# The csb0 switch on 2026-07-30 restarted tailscaled; one run saw all three
# Home Assistant instances as unreachable and paged immediately, then "recovered"
# 15 minutes later. Nothing had been wrong. One interval of delay on a real
# outage is a trade worth making against the four DAYS this machinery exists to
# prevent.
CONFIRM_RUNS = 2

Sender = Callable[[str, str], bool]


@dataclass(frozen=True)
class Problem:
    """One thing that is wrong. `key` is stable across runs; `text` is for humans."""

    key: str
    text: str


def atomic_write_state(path: str, state: dict) -> None:
    """Write state so a crash mid-write cannot corrupt it.

    A plain json.dump over the live file loses everything on a crash: the loader
    then falls back to empty state and every existing problem re-announces.
    """
    destination = Path(path)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=destination.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def load_state(path: str) -> dict:
    """Read state, tolerating absence, corruption and the pre-OPS-107 formats."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except Exception:
        return {"seen": {}, "pending": None}
    if not isinstance(raw, dict):
        return {"seen": {}, "pending": None}

    seen = raw.get("seen")
    if not isinstance(seen, dict):
        # ops-alerts v1 was {key: message}; v2 was {key: {msg, count, alerted}}.
        seen = {}
        for key, value in raw.items():
            if key == "pending":
                continue
            if isinstance(value, str):
                seen[key] = {"text": value, "count": CONFIRM_RUNS, "alerted": True}
            elif isinstance(value, dict) and "msg" in value:
                seen[key] = {
                    "text": value.get("msg", ""),
                    "count": int(value.get("count", CONFIRM_RUNS)),
                    "alerted": bool(value.get("alerted", False)),
                }
    pending = raw.get("pending")
    return {"seen": seen, "pending": pending if isinstance(pending, dict) else None}


def advance(previous: dict, problems: list[Problem]) -> tuple[dict, list[str], list[str]]:
    """Fold this run's problems into state; return (next_state, to_announce, cleared).

    `to_announce` holds only problems confirmed on CONFIRM_RUNS consecutive runs.
    `cleared` holds only problems that were actually announced -- otherwise a
    single blip produces a "recovered" message for something never reported.
    """
    seen_before = previous.get("seen", {})
    current = {p.key: p.text for p in problems}

    seen_now: dict[str, dict] = {}
    to_announce: list[str] = []
    for key, text in current.items():
        prior = seen_before.get(key, {})
        count = int(prior.get("count", 0)) + 1
        alerted = bool(prior.get("alerted", False))
        if count >= CONFIRM_RUNS and not alerted:
            to_announce.append(text)
            alerted = True
        seen_now[key] = {"text": text, "count": count, "alerted": alerted}

    cleared = [
        prior.get("text", key)
        for key, prior in seen_before.items()
        if key not in current and prior.get("alerted")
    ]
    return {"seen": seen_now, "pending": None}, to_announce, cleared


def event_id(stamp: float, announced: list[str], cleared: list[str]) -> str:
    """Stable id for one transition, so a retry is recognisably the same event."""
    import hashlib

    digest = hashlib.sha256()
    digest.update(str(int(stamp // 60)).encode())
    for item in sorted(announced) + ["|"] + sorted(cleared):
        digest.update(item.encode())
    return digest.hexdigest()[:12]


def telegram_sender(token: str, chat_id: str) -> Sender:
    """Sender posting to Telegram. Credentials are never logged."""

    def send(text: str, identifier: str) -> bool:
        payload = urllib.parse.urlencode(
            {"chat_id": chat_id, "text": text, "disable_web_page_preview": "true"}
        ).encode()
        url = urllib.parse.urlunsplit(
            ("https", "api.telegram.org", f"/bot{token}/sendMessage", "", "")
        )
        request = urllib.request.Request(url, data=payload)
        try:
            with urllib.request.urlopen(  # noqa: S310 - scheme and host are literals
                request,
                timeout=NETWORK_TIMEOUT_SECONDS,
                context=ssl.create_default_context(),
            ):
                return True
        except Exception as error:  # noqa: BLE001
            print(f"delivery failed for {identifier}: {type(error).__name__}")
            return False

    return send


def env_file_value(path: str, key: str) -> str:
    """One value out of a KEY=VALUE env file. Never logs the file's contents."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except Exception:
        return ""
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line.removeprefix("export ").lstrip()
        name, separator, value = line.partition("=")
        if separator and name.strip() == key:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            return value.strip()
    return ""


def shoutrrr_telegram_sender(url: str) -> Sender:
    """Sender from a shoutrrr `telegram://TOKEN@telegram?chats=ID` URL.

    Lets csb1 reuse its existing WATCHTOWER_NOTIFICATION_URL secret unchanged --
    no agenix edit, no second credential to rotate. Format mirrors
    hausv-alerts-poll.py's parse_notification_target so the two cannot drift.
    """
    parsed = urllib.parse.urlsplit(url.strip())
    if parsed.scheme != "telegram" or parsed.hostname != "telegram" or "@" not in parsed.netloc:
        raise ValueError("unsupported notification target")
    token = urllib.parse.unquote(parsed.netloc.rsplit("@", 1)[0])
    query = urllib.parse.parse_qs(parsed.query)
    recipients = [
        item.strip()
        for value in (query.get("chats") or query.get("channels") or [])
        for item in value.split(",")
        if item.strip().lstrip("-").isdigit()
    ]
    if not token or not recipients:
        raise ValueError("unsupported notification target")

    senders = [telegram_sender(token, chat) for chat in recipients]

    def send(text: str, identifier: str) -> bool:
        # All recipients must receive it, or the cycle retries for everyone --
        # partial delivery would leave the write-ahead log claiming success.
        return all(one(text, identifier) for one in senders)

    return send


def run_cycle(
    state_path: str,
    stamp: float,
    check: Callable[[], list[Problem]],
    render: Callable[[list[str], list[str]], str],
    sender: Sender,
) -> int:
    """One poll. See the module docstring for the write-ahead-log contract."""
    state = load_state(state_path)

    # An alert left undelivered by a previous run is re-sent verbatim before any
    # new evaluation, so ordering is preserved and nothing is silently dropped.
    pending = state.get("pending")
    if isinstance(pending, dict) and pending.get("text"):
        if not sender(pending["text"], pending.get("event_id", "retry")):
            print("still undelivered; leaving pending in place")
            return EXIT_UNDELIVERED
        atomic_write_state(state_path, pending.get("next_state") or {"seen": {}, "pending": None})
        state = load_state(state_path)

    problems = check()
    next_state, announce, cleared = advance(state, problems)

    if announce or cleared:
        text = render(announce, cleared)
        identifier = event_id(stamp, announce, cleared)
        # Write-ahead: pending is durable BEFORE the send is attempted.
        staged = dict(state)
        staged["pending"] = {"event_id": identifier, "text": text, "next_state": next_state}
        atomic_write_state(state_path, staged)
        if not sender(text, identifier):
            return EXIT_UNDELIVERED
        print(text)

    atomic_write_state(state_path, next_state)

    pending_confirm = sum(1 for v in next_state["seen"].values() if not v["alerted"])
    print(
        f"ok — {len(problems)} active problem(s), "
        f"{pending_confirm} awaiting confirmation"
    )
    return EXIT_PROBLEMS if problems else EXIT_CLEAN
