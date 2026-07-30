#!/usr/bin/env python3
"""OPS-104 checks for csb0, running on the shared OPS-107 engine.

The engine owns durability (write-ahead delivery, atomic state, confirm-before-
alert). This file owns only WHAT is checked and HOW it reads to a human.
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

import engine
from engine import Problem

STATE_PATH = "/var/lib/ops-alerts/state.json"
TIMEOUT = 15

# Substituted by ops-alerts.nix at build time, so the built script holds literals
# and no runtime data reaches a request URL (CodeQL partial-SSRF, 2026-07-30).
TARGETS = json.loads(r"""@TARGETS_JSON@""")
PEERS = json.loads(r"""@PEERS_JSON@""")

# Only tailnet Home Assistant addresses may ever be requested. Anchored and
# narrow so the SSRF shape is unreachable rather than merely unlikely, and so a
# typo in the Nix target list fails loudly here instead of quietly sending a
# bearer token somewhere unintended.
ALLOWED_BASE = re.compile(r"^http://100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}:8123$")


def ha_get(base: str, token: str, path: str):
    if not ALLOWED_BASE.match(base):
        raise ValueError("target base URL is not an allowed tailnet HA address")
    if not path.startswith("/api/"):
        raise ValueError("path must stay under /api/")
    request = urllib.request.Request(
        urllib.parse.urljoin(base, path), headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310
        return json.loads(response.read().decode())


def check_home_assistant(target: dict) -> list[Problem]:
    name = target["name"]
    token = os.environ.get(target["tokenVar"], "")
    if not token:
        return [Problem(f"{name}:token", f"{name}: no API token in the environment")]

    # 1. Is Home Assistant answering at all? The check no in-HA automation can
    #    ever perform on itself.
    try:
        ha_get(target["url"], token, "/api/")
    except urllib.error.HTTPError as error:
        return [Problem(f"{name}:api", f"{name}: HA API returned HTTP {error.code}")]
    except Exception as error:  # noqa: BLE001 - any failure here means unreachable
        return [Problem(f"{name}:api", f"{name}: HA unreachable ({type(error).__name__})")]

    found: list[Problem] = []

    # 2. Did a config entry fail to load? 'unavailable' means the entry is not
    #    loaded. 'unknown' is a healthy but SLEEPING car and must NOT alert --
    #    tesla_fleet sets updated_once only after a successful vehicle_data fetch,
    #    so a parked car reports 'unknown' for hours.
    witness = target.get("witness")
    if witness:
        try:
            state = ha_get(target["url"], token, f"/api/states/{witness}").get("state")
            if state == "unavailable":
                found.append(
                    Problem(
                        f"{name}:entry",
                        f"{name}: Tesla integration not loaded ({witness} is unavailable). "
                        f"The self-heal automation should reload it within the hour.",
                    )
                )
        except Exception as error:  # noqa: BLE001
            found.append(
                Problem(f"{name}:entry", f"{name}: cannot read {witness} ({type(error).__name__})")
            )

    # 3. Is the Fleet API budget burning faster than planned?
    budget = target.get("budgetEntity")
    if budget:
        try:
            used = int(float(ha_get(target["url"], token, f"/api/states/{budget}").get("state")))
            limit = target.get("budgetLimit", 0)
            if used > limit:
                found.append(
                    Problem(
                        f"{name}:budget",
                        f"{name}: Tesla API budget at {used} billed polls this month "
                        f"(threshold {limit}). Check that built-in polling was not "
                        f"re-enabled and that no new vehicle joined the account.",
                    )
                )
        except Exception:  # noqa: BLE001 - a missing counter is not an outage
            pass

    return found


def check_peer(peer: dict) -> list[Problem]:
    """Is the peer host's poller still running? See heartbeat.nix for the design.

    A host cannot detect its own death, so csb0 and csb1 check each other. The
    heartbeat is the peer's state-file mtime, served as one integer over the
    tailnet.
    """
    name = peer["name"]
    try:
        with socket.create_connection((peer["address"], peer["port"]), timeout=TIMEOUT) as sock:
            raw = sock.recv(64).decode().strip()
        stamp = float(raw)
    except Exception as error:  # noqa: BLE001
        return [
            Problem(
                f"peer:{name}",
                f"{name}: poller heartbeat unreachable ({type(error).__name__}). "
                f"That host may be down, or its alert poller stopped -- so its own "
                f"alerts would be silent.",
            )
        ]

    if stamp <= 0:
        return [Problem(f"peer:{name}", f"{name}: poller has never recorded a run")]

    age = int(time.time() - stamp)
    if age > peer["maxAgeSeconds"]:
        return [
            Problem(
                f"peer:{name}",
                f"{name}: poller last ran {age // 60} min ago "
                f"(limit {peer['maxAgeSeconds'] // 60} min). Its alerts are not firing.",
            )
        ]
    return []


def collect() -> list[Problem]:
    found: list[Problem] = []
    for target in TARGETS:
        found.extend(check_home_assistant(target))
    for peer in PEERS:
        found.extend(check_peer(peer))
    return found


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f534 Fleet problem:"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["✅ Cleared — no longer failing:"] + [f"• {item}" for item in cleared]
    return "\n".join(lines)


def main() -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("TELEGRAM_CHAT_ID", "")
    # Shape-validated before reaching a URL: Telegram requires the token in the
    # path, so this is what stops a malformed value steering the request.
    if not re.match(r"^\d{5,20}:[A-Za-z0-9_-]{20,255}$", token) or not re.match(
        r"^-?\d{1,32}$", chat
    ):
        print("telegram credentials missing or malformed", flush=True)
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(
        STATE_PATH, time.time(), collect, render, engine.telegram_sender(token, chat)
    )


if __name__ == "__main__":
    raise SystemExit(main())
