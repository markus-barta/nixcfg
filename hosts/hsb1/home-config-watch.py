#!/usr/bin/env python3
"""OPS-158: independent metadata-only witness using the shared OPS-107 engine."""

from pathlib import Path
import stat
import time

import engine
from engine import Problem


STATE_PATH = "/var/lib/home-config-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
SUCCESS = Path("/home/mba/home-config/.git/snapshot-success")
MAX_AGE = 45 * 60


def check_freshness(path, now):
    try:
        info = path.lstat()
    except OSError:
        return [Problem("home-config:missing", "hsb1: configuration snapshot success witness is missing; check hsb1-home-config.service.")]
    if not stat.S_ISREG(info.st_mode) or not 0 <= now - info.st_mtime <= MAX_AGE:
        return [Problem("home-config:stale", "hsb1: no successful configuration snapshot within 45 minutes; check its secret gate, timer and service.")]
    return []


def collect():
    return check_freshness(SUCCESS, time.time())


def render(announced, cleared):
    return "\n".join(["hsb1 configuration history:"] + announced + ["Cleared: " + item for item in cleared])


def main():
    target = engine.env_file_value(NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL")
    if not target:
        print("notification target missing")
        return engine.EXIT_UNDELIVERED
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError:
        print("notification target unusable")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(STATE_PATH, time.time(), collect, render, sender)


if __name__ == "__main__":
    raise SystemExit(main())
