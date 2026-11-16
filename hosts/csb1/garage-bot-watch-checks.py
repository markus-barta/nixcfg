#!/usr/bin/env python3
"""Watch the garage Telegram bot (Node-RED on csb0) independently — OPS-604.

getWebhookInfo observes the queue without consuming messages. A positive
pending_update_count on two consecutive five-minute runs means the receiver
is not keeping up, even if sending still works (OPS-603). The OPS-107 engine
owns confirmation, durable notification delivery and recovery transitions.
"""

from __future__ import annotations

import json
import re
import ssl
import time
import urllib.parse
import urllib.request

import engine
from engine import Problem

STATE_PATH = "/var/lib/garage-bot-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
POLLING_KEY = "garage-bot:not-polling"
POLLING_REMINDER_SECONDS = 6 * 3600


def reminder_interval(key: str) -> int | None:
    return POLLING_REMINDER_SECONDS if key == POLLING_KEY else None


def notification_token(target: str) -> str:
    """Extract only a Telegram token; parser errors must never echo credentials."""
    try:
        parsed = urllib.parse.urlsplit(target.strip())
        token = urllib.parse.unquote(parsed.netloc.rsplit("@", 1)[0])
        if (
            parsed.scheme == "telegram"
            and parsed.netloc.endswith("@telegram")
            and parsed.path in ("", "/")
            and not parsed.fragment
            and re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token)
        ):
            return token
    except Exception:  # noqa: BLE001
        pass
    raise ValueError("unsupported notification target") from None


def unreadable() -> list[Problem]:
    found = [Problem(
        "garage-bot:unreadable",
        "garage Telegram bot: Telegram queue unreadable; polling on csb0 is "
        "currently unwatched (OPS-603). Check Telegram API connectivity and "
        "the csb1-watchtower-env credential.",
    )]
    # As in fleet-drift: unavailable evidence cannot prove recovery. Preserve
    # only an announced polling alarm, so an unconfirmed blip still resets.
    prior = engine.load_state(STATE_PATH).get("seen", {}).get(POLLING_KEY, {})
    if isinstance(prior, dict) and prior.get("alerted"):
        text = prior.get("text") or "garage Telegram bot: polling on csb0 has not recovered (OPS-603)."
        found.append(Problem(POLLING_KEY, text))
    return found


def collect(token: str) -> list[Problem]:
    try:
        url = urllib.parse.urlunsplit(
            ("https", "api.telegram.org", f"/bot{token}/getWebhookInfo", "", "")
        )
        request = urllib.request.Request(url)
        with urllib.request.urlopen(  # noqa: S310 -- scheme and host are literals
            request,
            timeout=engine.NETWORK_TIMEOUT_SECONDS,
            context=ssl.create_default_context(),
        ) as response:
            data = json.load(response)
        if not isinstance(data, dict) or data.get("ok") is not True:
            return unreadable()
        result = data.get("result")
        count = result.get("pending_update_count") if isinstance(result, dict) else None
        if type(count) is not int or count < 0:
            return unreadable()
    except Exception:  # noqa: BLE001
        # HTTP errors, response bodies and parser errors may contain the token
        # or the complete URL. Never interpolate any part of the exception.
        return unreadable()
    if count == 0:
        return []
    return [Problem(
        POLLING_KEY,
        f"garage Telegram bot: {count} messages waiting — Node-RED on csb0 is "
        "not polling (OPS-603). Fix: restart csb0-nodered-1 after dropping stale updates.",
    )]


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["🔴 Garage bot watch:"] + [f"• {item}" for item in announced]
    if cleared:
        lines.append("✅ Garage bot watch — observation cleared:")
        # The engine supplies prior problem text, rather than keys, on recovery.
        for item in cleared:
            if item.startswith("garage Telegram bot: Telegram queue unreadable;"):
                lines.append("• garage Telegram bot: Telegram queue readable again.")
            else:
                lines.append(
                    "• garage Telegram bot: queue empty — either Node-RED resumed, "
                    "or the messages expired after Telegram's 24 h retention; "
                    "confirm the bot answers."
                )
    return "\n".join(lines)


def main() -> int:
    target = engine.env_file_value(NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL")
    try:
        token = notification_token(target)
        sender = engine.shoutrrr_telegram_sender(target)
    except Exception:  # noqa: BLE001
        print("notification target missing or unusable")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(
        STATE_PATH, time.time(), lambda: collect(token), render, sender,
        reminder_interval=reminder_interval,
    )


if __name__ == "__main__":
    raise SystemExit(main())
