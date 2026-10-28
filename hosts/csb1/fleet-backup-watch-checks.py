#!/usr/bin/env python3
"""Fleet backup watch — OPS-485.

The backup dead-man's switch. Every host's restic job writes a status file that
its Pharos beacon reports as-is (PHAROS_BACKUP_MODE=status-file, OPS-53), and
pharosd already pages a `failed` or `stale` state within minutes (alerts.rs).
Nothing ages that file, though: if the nightly job never runs again (cron dead,
container stopped, image broken before the script starts), the file keeps its
last "healthy" verdict and Pharos shows a green backup forever. On hsb8/hsb9
the job's own failure mail cannot leave the box either (no relay there; OPS-137
chose "no mail on family servers"), so before this unit nobody would notice.

This reads pharosd's persisted store on csb1 (root, read-only, the same data the
UI renders; `/hosts.json` needs an OIDC session even on localhost) and pages per
backup observation, for every host that reports one:

  * `age`   -- no successful run within the schedule's limit (26 h for daily),
               whatever the reported state says. A failed nightly also lands
               here ~2 h after pharosd's immediate page, as the reminder that it
               is still not fixed.
  * `state` -- warning / missing / unknown, which pharosd does not page.

`failed` and `stale` states are deliberately not paged a second time here.
No host list: Pharos is the inventory. When the store, or one host's entry,
cannot be judged, the problems already announced stay open (carried forward
from the engine state) next to a loud "unwatched" problem, so broken evidence
never reads as a recovery.
"""

from __future__ import annotations

import json
import time

import engine
from engine import Problem

STATE_PATH = "/var/lib/fleet-backup-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
STORE_PATH = "@STORE_PATH@"
# A nightly job plus two hours of slack for a slow run or a late cron.
DEFAULT_MAX_AGE_HOURS = 26
MAX_AGE_HOURS = {"daily": 26, "weekly": 8 * 24}
# pharosd opens its own backup incident for these (alerts.rs reconcile_backup).
PAGED_BY_PHAROS = {"failed", "stale"}
QUIET_STATES = {"healthy"}
# Beacon silence beyond this makes the reported status itself old news.
STALE_SECONDS = 30 * 60


def load_store(path: str) -> list:
    """The host list. Any other shape raises: it must never read as an empty fleet."""
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("hosts")
    if not isinstance(data, list):
        raise ValueError("store is not a host list")
    return data


def epoch(value: object) -> float | None:
    """A positive unix time, or None. bool is an int in Python and is rejected."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        return None
    return float(value)


def carried_forward(prefix: str = "backup:") -> list[Problem]:
    """Already-announced problems, kept open while their evidence cannot be judged.

    Without this an unusable store (or host entry) looks like "no problems", and
    the engine would announce every open alert as cleared.
    """
    seen = engine.load_state(STATE_PATH).get("seen", {})
    return [Problem(key, str(entry.get("text") or key)) for key, entry in seen.items()
            if key.startswith(prefix) and key != "backup:store"
            and isinstance(entry, dict) and entry.get("alerted")]


def judge(host: dict, now: float) -> list[Problem]:
    name = str(host.get("name") or "?")
    observations = host.get("backup_observations") or []
    if not isinstance(observations, list):
        raise ValueError("backup_observations is not a list")
    seen = epoch(host.get("last_seen"))
    silent = seen is None or now - seen > STALE_SECONDS
    found: list[Problem] = []
    for observation in observations:
        if not isinstance(observation, dict):
            continue
        state = str(observation.get("state") or "unknown")
        if state == "not-configured" or observation.get("configured") == "disabled":
            continue
        ident = str(observation.get("id") or "backup")
        label = str(observation.get("label") or ident)
        key = f"backup:{name}:{ident}"
        summary = str(observation.get("summary") or "no summary")

        if state not in QUIET_STATES and state not in PAGED_BY_PHAROS:
            found.append(Problem(f"{key}:state", f"{name}: {label} reports {state} ({summary})."))

        limit_hours = MAX_AGE_HOURS.get(str(observation.get("schedule") or ""), DEFAULT_MAX_AGE_HOURS)
        last = epoch(observation.get("last_success_at"))
        if last is None:
            found.append(Problem(f"{key}:age", f"{name}: {label} has never recorded a successful run."))
            continue
        age_hours = (now - last) / 3600.0
        if age_hours <= limit_hours:
            continue
        text = (f"{name}: {label} last succeeded {age_hours:.1f} h ago (limit {limit_hours} h). "
                f"Check the {ident} job on {name}.")
        if silent:
            heard = f"has not heard from {name} for {int((now - seen) // 60)} min" if seen else f"has no last-seen time for {name}"
            text += f" Pharos {heard}, so this status may be older still."
        found.append(Problem(f"{key}:age", text))
    return found


def collect() -> list[Problem]:
    try:
        hosts = load_store(STORE_PATH)
    except Exception as error:  # noqa: BLE001
        return carried_forward() + [Problem("backup:store", f"pharosd store unusable at {STORE_PATH} ({type(error).__name__}); "
                                                            f"fleet backups are currently unwatched.")]
    now = time.time()
    found: list[Problem] = []
    if any(not isinstance(h, dict) for h in hosts):
        found.append(Problem("backup:store:entry", "pharosd store holds a host entry that is not an object; "
                                                   "that host's backups are unwatched."))
    hosts = [h for h in hosts if isinstance(h, dict)]
    watched = sum(len(h["backup_observations"]) for h in hosts if isinstance(h.get("backup_observations"), list))
    if not watched:
        return carried_forward() + found + [Problem("backup:store", "pharosd store lists no backup observations; "
                                                                    "fleet backups are currently unwatched.")]
    for host in sorted(hosts, key=lambda h: str(h.get("name"))):
        name = str(host.get("name") or "?")
        try:
            found.extend(judge(host, now))
        except Exception as error:  # noqa: BLE001
            found.extend(carried_forward(f"backup:{name}:"))
            found.append(Problem(f"backup:{name}:malformed", f"{name}: Pharos backup data could not be judged "
                                                             f"({type(error).__name__}); its backups are unwatched."))
    return found


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f4be Fleet backups:"] + [f"• {item}" for item in announced]
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
