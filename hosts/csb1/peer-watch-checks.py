#!/usr/bin/env python3
"""csb1's half of the mutual poller watch — OPS-107.

Deliberately separate from hausv-alerts-poll.py rather than a check bolted into
it: that poller is mature, hardened and covered by T34, and adding an unrelated
fleet concern to it would mean editing working product monitoring for something
orthogonal. This is a second, tiny unit with one job.

It answers only: is csb0's alert poller still running? csb0 watches the three
Home Assistant instances and is the only thing that would report them broken, so
if its poller stops, that silence must be reported by somebody else. A host
cannot detect its own death.

Reuses csb1's existing WATCHTOWER_NOTIFICATION_URL so no new secret is needed.
"""

from __future__ import annotations

import json
import socket
import time

import engine
from engine import Problem

STATE_PATH = "/var/lib/fleet-peer-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
PEERS = json.loads(r"""@PEERS_JSON@""")
TIMEOUT = 15


def check_peer(peer: dict) -> list[Problem]:
    name = peer["name"]
    try:
        with socket.create_connection((peer["address"], peer["port"]), timeout=TIMEOUT) as sock:
            stamp = float(sock.recv(64).decode().strip())
    except Exception as error:  # noqa: BLE001
        return [
            Problem(
                f"peer:{name}",
                f"{name}: alert poller heartbeat unreachable ({type(error).__name__}). "
                f"That host may be down, or its poller stopped -- either way the Home "
                f"Assistant fleet is currently unwatched.",
            )
        ]
    if stamp <= 0:
        return [Problem(f"peer:{name}", f"{name}: alert poller has never recorded a run")]
    age = int(time.time() - stamp)
    if age > peer["maxAgeSeconds"]:
        return [
            Problem(
                f"peer:{name}",
                f"{name}: alert poller last ran {age // 60} min ago "
                f"(limit {peer['maxAgeSeconds'] // 60} min). The HA fleet is unwatched.",
            )
        ]
    return []


def collect() -> list[Problem]:
    found: list[Problem] = []
    for peer in PEERS:
        found.extend(check_peer(peer))
    return found


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f534 Fleet watchdog:"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["✅ Cleared — no longer failing:"] + [f"• {item}" for item in cleared]
    return "\n".join(lines)


def main() -> int:
    target = engine.env_file_value(NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL")
    if not target:
        print("notification target missing")
        return engine.EXIT_UNDELIVERED
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError as error:
        print(f"notification target unusable: {error}")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(STATE_PATH, time.time(), collect, render, sender)


if __name__ == "__main__":
    raise SystemExit(main())
