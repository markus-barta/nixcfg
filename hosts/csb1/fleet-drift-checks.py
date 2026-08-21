#!/usr/bin/env python3
"""Fleet drift watch — OPS-187.

Pages when a fleet host runs a nixcfg generation that is persistently behind
`main`. 2026-08-21: csb0 sat two weeks behind main (its checkout parked on a
stale branch), hsb8/hsb9 ~100 commits behind — nothing said so. Pharos already
knows: every beacon reports deployment evidence + a git comparison against the
authoritative nixcfg remote, and pharosd persists it. `/hosts.json` needs an
OIDC session even on localhost, so this reads pharosd's persisted store on csb1
(root, read-only) — the same data the UI renders.

One problem per host (key `drift:<host>`) when the beacon says `relation=behind`
and either the deployed commit is older than MAX_AGE_DAYS (commit date looked up
in the local nixcfg checkout, best effort) or it is at least MAX_COMMITS behind.
`diverged` / `ahead` are problems of their own. Hosts not seen for STALE_SECONDS
are skipped — Pharos' own HostDown incident covers them. Hosts whose beacon
carries no evidence are skipped (nothing to judge).

Depends on OPS-186 (beacons must see the CURRENT evidence; before that fix the
numbers lag the beacon container's start time).
"""

from __future__ import annotations

import json
import subprocess
import time

import engine
from engine import Problem

STATE_PATH = "/var/lib/fleet-drift/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
STORE_PATH = "@STORE_PATH@"
NIXCFG_CHECKOUT = "@NIXCFG_CHECKOUT@"
GIT = "@GIT_BIN@"
MAX_AGE_DAYS = 7
MAX_COMMITS = 25
STALE_SECONDS = 30 * 60


def load_store(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("hosts") or []
    return [h for h in data if isinstance(h, dict)]


def commit_age_days(revision: str, now: float) -> float | None:
    """Age of a commit in the local nixcfg checkout; None if unknown (no fetch here)."""
    if not revision or len(revision) < 7:
        return None
    try:
        completed = subprocess.run(  # noqa: S603 -- literal argv, substituted at build
            [GIT, "-c", f"safe.directory={NIXCFG_CHECKOUT}", "-C", NIXCFG_CHECKOUT,
             "log", "-1", "--format=%ct", revision],
            capture_output=True, text=True, timeout=15, check=True,
        )
        stamp = float(completed.stdout.strip())
    except Exception:  # noqa: BLE001
        return None
    return max(0.0, (now - stamp) / 86400.0)


def judge(host: dict, now: float) -> list[Problem]:
    name = str(host.get("name") or "?")
    if not host.get("is_nix"):
        return []
    seen = float(host.get("last_seen") or 0)
    if now - seen > STALE_SECONDS:
        return []  # Pharos HostDown owns silence
    fresh = host.get("freshness") or {}
    comparison = fresh.get("nixcfg_comparison") or {}
    relation = comparison.get("relation")
    evidence = fresh.get("deployment_evidence") or {}
    revision = str(evidence.get("source_revision") or "")
    if relation in (None, "", "current"):
        return []
    if relation in ("diverged", "ahead"):
        return [Problem(f"drift:{name}:relation",
                        f"{name}: deployed nixcfg {revision[:8]} is {relation} of main — "
                        f"somebody switched from a branch or a dirty tree; reconcile before the next change.")]
    behind = comparison.get("commits_behind")
    behind = int(behind) if isinstance(behind, (int, float)) else None
    age = commit_age_days(revision, now)
    if (age is not None and age >= MAX_AGE_DAYS) or (behind is not None and behind >= MAX_COMMITS):
        age_text = f"{int(age)} d old" if age is not None else "age unknown"
        behind_text = f"{behind} commits behind main" if behind is not None else "behind main"
        return [Problem(f"drift:{name}",
                        f"{name}: deployed nixcfg {revision[:8]} is {behind_text} ({age_text}). "
                        f"ssh {name} 'cd ~/Code/nixcfg && git pull && just switch' after reviewing the delta.")]
    return []


def collect() -> list[Problem]:
    try:
        hosts = load_store(STORE_PATH)
    except Exception as error:  # noqa: BLE001
        return [Problem("drift:store", f"pharosd store unreadable at {STORE_PATH} ({type(error).__name__}); "
                                       f"fleet drift is currently unwatched.")]
    now = time.time()
    found: list[Problem] = []
    for host in sorted(hosts, key=lambda h: str(h.get("name"))):
        found.extend(judge(host, now))
    return found


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f7e0 Fleet drift:"] + [f"• {item}" for item in announced]
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
