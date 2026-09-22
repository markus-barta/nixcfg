#!/usr/bin/env python3
"""IR bridge witness — OPS-223.

On 2026-09-21 the IR → Sony TV path on hsb1 was dead twice in one evening and
nothing paged. First the FLIRC failed USB enumeration after a reboot: the bridge
kept running, logged "unavailable — retrying in 30s" and was deaf for ~4 h. Once
the stick was replugged, the TV's own Sony REST API answered HTTP 404 to every
IRCC POST until the TV was power-cycled. The remote going dead was the only
alarm, both times.

A small OPS-107 poller (shared engine: confirm-before-alert, write-ahead
delivery) with three checks. Each has its own problem key, so they page and
clear independently:

  * ir-bridge:unit   ir-bridge.service has no process. Read from the unit's
                     cgroup (/sys/fs/cgroup/system.slice/<unit>/cgroup.procs,
                     the documented systemd cgroup layout): non-empty exactly
                     while the service runs, readable under ProtectSystem=strict
                     and needing no D-Bus socket. (Not the
                     /run/systemd/units/invocation:* marker: that is journald
                     plumbing and a dangling symlink, so exists() lies.)
  * ir-bridge:flirc  the FLIRC's stable by-id input node is missing. It is the
                     exact path the bridge opens, so this means "the bridge is
                     deaf", whatever the USB reason (OPS-222).
  * tv:api           the TV is reachable but its Sony API answers 404/5xx (or
                     not JSON) to the unauthenticated, read-only
                     system.getPowerStatus. A TV that is off, unplugged or
                     unreachable is NOT a problem — nothing to page for — so
                     transport errors clear this check.

Timer: 5 min. The engine confirms on two consecutive runs, so a real failure
pages 5–10 min after onset while a reboot's USB settle time never does.
Notification: the same WATCHTOWER_NOTIFICATION_URL env file as tailnet-watch
(hsb1-tailnet-watch-env) — no new secret.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

import engine
from engine import Problem

STATE_PATH = "/var/lib/ir-bridge-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
FLIRC_DEVICE = "@FLIRC_DEVICE@"
SONY_SYSTEM_URL = "@SONY_SYSTEM_URL@"
UNIT_CGROUP_PROCS = "/sys/fs/cgroup/system.slice/ir-bridge.service/cgroup.procs"
TIMEOUT = 5
MAX_BODY = 65536


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The TV endpoint is a build-time literal; never follow it anywhere else."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def unit_has_process() -> bool:
    """True while ir-bridge.service owns at least one process (cgroup v2)."""
    try:
        with open(UNIT_CGROUP_PROCS, encoding="utf-8") as handle:
            return any(line.strip() for line in handle)
    except OSError:
        # No cgroup = the unit is not running (systemd removes it on stop).
        return False


def check_unit() -> list[Problem]:
    if unit_has_process():
        return []
    return [
        Problem(
            "ir-bridge:unit",
            "hsb1: ir-bridge.service is not running — the remote is dead on both "
            "paths. `systemctl status ir-bridge` on hsb1.",
        )
    ]


def check_flirc() -> list[Problem]:
    if os.path.exists(FLIRC_DEVICE):
        return []
    return [
        Problem(
            "ir-bridge:flirc",
            "hsb1: FLIRC receiver is missing from /dev/input — the bridge runs but "
            "is deaf. `journalctl -k | grep usb` for enumeration errors on its hub "
            "port, then replug the stick (OPS-222); the bridge reopens it by itself.",
        )
    ]


def tv_api_status() -> str:
    """One word for the TV's Sony API: ok, unreachable, http_<code> or invalid."""
    body = json.dumps(
        {"method": "getPowerStatus", "id": 50, "params": [], "version": "1.0"}
    ).encode()
    request = urllib.request.Request(
        SONY_SYSTEM_URL, data=body, headers={"Content-Type": "application/json"}
    )
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=TIMEOUT) as response:  # noqa: S310 - literal URL
            raw = response.read(MAX_BODY)
    except urllib.error.HTTPError as error:
        error.close()
        return f"http_{error.code}"
    except Exception:  # noqa: BLE001 - off, unplugged, DNS, timeout: all "unreachable"
        return "unreachable"
    try:
        payload = json.loads(raw)
    except ValueError:
        return "invalid"
    if isinstance(payload, dict) and isinstance(payload.get("result"), list):
        return "ok"
    return "invalid"


def check_tv_api() -> list[Problem]:
    status = tv_api_status()
    if status in ("ok", "unreachable"):
        return []
    return [
        Problem(
            "tv:api",
            f"hsb1: Sony TV is reachable but its control API answers {status} to "
            "getPowerStatus — every IRCC press fails (2026-09-21 failure mode). "
            "Restart the TV: hold the power button on the remote → Restart, or "
            "mains power-cycle.",
        )
    ]


def collect() -> list[Problem]:
    return check_unit() + check_flirc() + check_tv_api()


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f534 IR bridge (hsb1):"] + [f"• {item}" for item in announced]
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
