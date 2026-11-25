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
GC_MAX_AGE = 15 * 24 * 60 * 60
GC_LOCK_MAX_AGE = 60 * 60  # Longer than the GC unit's thirty-minute limit.
GC_LOCKS = ("packed-refs.lock", "gc.pid", "gc.pid.lock", "gc.log.lock",
            "objects/info/commit-graph.lock", "objects/info/commit-graphs/commit-graph-chain.lock")


def check_freshness(path, now):
    try:
        info = path.lstat()
    except OSError:
        return [Problem("home-config:missing", "hsb1: configuration snapshot success witness is missing; check hsb1-home-config.service.")]
    if not stat.S_ISREG(info.st_mode) or not 0 <= now - info.st_mtime <= MAX_AGE:
        return [Problem("home-config:stale", "hsb1: no successful configuration snapshot within 45 minutes; check its secret gate, timer and service.")]
    return []


def check_gc(git_dir, now):
    problems = []
    try:
        try:
            info = (git_dir / "gc-success").lstat()
        except FileNotFoundError:
            # Give a newly initialized repository time for its first weekly GC;
            # snapshots never refresh config or masquerade as GC success.
            info = (git_dir / "config").lstat()
        if not stat.S_ISREG(info.st_mode) or not 0 <= now - info.st_mtime <= GC_MAX_AGE:
            problems.append(Problem("home-config:gc-stale", "hsb1: no successful configuration history GC within 15 days; check hsb1-home-config-gc.service."))
    except OSError:
        problems.append(Problem("home-config:gc-missing", "hsb1: configuration history GC witness is missing; check hsb1-home-config-gc.service."))
    for name in GC_LOCKS:
        try:
            info = (git_dir / name).lstat()
        except FileNotFoundError:
            continue
        except OSError:
            problems.append(Problem("home-config:gc-lock:" + name, "hsb1: cannot inspect configuration history GC lock " + name + "; check hsb1-home-config-gc.service."))
            continue
        if not stat.S_ISREG(info.st_mode) or not 0 <= now - info.st_mtime <= GC_LOCK_MAX_AGE:
            # Alert rather than deleting possible operator/concurrent Git work.
            problems.append(Problem("home-config:gc-lock:" + name, "hsb1: stale or invalid configuration history GC lock " + name + "; inspect hsb1-home-config-gc.service before recovery."))
    return problems


def collect():
    now = time.time()
    return check_freshness(SUCCESS, now) + check_gc(SUCCESS.parent, now)


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
