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
No host list: Pharos is the inventory. One rule guards recovery (collect()):
an announced problem clears only when this run re-judged exactly its evidence.
Missing or malformed evidence keeps it open next to a loud "unwatched" problem.
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


def announced() -> dict[str, str]:
    """Problems this unit has already announced (engine state), key -> text."""
    seen = engine.load_state(STATE_PATH).get("seen", {})
    return {key: str(entry.get("text") or key) for key, entry in seen.items()
            if isinstance(entry, dict) and entry.get("alerted")}


def valid_name(value: object) -> bool:
    return isinstance(value, str) and bool(value) and ":" not in value


def judge(host: dict, now: float) -> tuple[list[Problem], set[str]]:
    """One well-named host entry: its problems, and the exact keys it re-judged.

    A key is "re-judged" only when this run evaluated the evidence that produces
    it: `<id>:state` and `<id>:age` for each well-formed, configured observation,
    and `malformed` once the observation container itself was readable.
    """
    name = host["name"]
    malformed_key = f"backup:{name}:malformed"
    observations = host.get("backup_observations", [])
    if observations is None:
        observations = []
    if not isinstance(observations, list):
        return [Problem(malformed_key, f"{name}: Pharos reports its backups in an unexpected shape; "
                                       f"they are unwatched.")], set()
    seen = epoch(host.get("last_seen"))
    silent = seen is None or now - seen > STALE_SECONDS
    found: list[Problem] = []
    judged = {malformed_key}
    unreadable = 0
    for observation in observations:
        ident = observation.get("id") if isinstance(observation, dict) else None
        if not valid_name(ident):
            unreadable += 1
            continue
        state = observation.get("state")
        state = state if isinstance(state, str) and state else "unknown"
        # Deliberately unconfigured: nothing to judge, so an open alert stays open.
        if state == "not-configured" or observation.get("configured") == "disabled":
            continue
        key = f"backup:{name}:{ident}"
        judged |= {f"{key}:state", f"{key}:age"}
        label = str(observation.get("label") or ident)
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
    if unreadable:
        found.append(Problem(malformed_key, f"{name}: {unreadable} backup observation(s) in an unexpected shape; "
                                            f"those backups are unwatched."))
    return found, judged


def collect() -> list[Problem]:
    """This run's problems, plus every announced problem it could not re-judge.

    The one rule: an announced problem clears only when this run evaluated
    exactly its evidence and found it clean. Any missing or malformed evidence
    (unusable store, unnamed entry, host gone from Pharos, broken observation)
    therefore keeps the alert open instead of reading as a recovery. The store
    keys are evaluated on every run.
    """
    found: list[Problem] = []
    judged = {"backup:store", "backup:store:entry"}
    try:
        hosts = load_store(STORE_PATH)
    except Exception as error:  # noqa: BLE001
        hosts = []
        found.append(Problem("backup:store", f"pharosd store unusable at {STORE_PATH} ({type(error).__name__}); "
                                             f"fleet backups are currently unwatched."))
    else:
        named = [h for h in hosts if isinstance(h, dict) and valid_name(h.get("name"))]
        if len(named) < len(hosts):
            found.append(Problem("backup:store:entry", f"pharosd store holds {len(hosts) - len(named)} host "
                                                       f"entr(y/ies) without a usable name; their backups are unwatched."))
        now = time.time()
        for host in sorted(named, key=lambda h: h["name"]):
            try:
                problems, host_judged = judge(host, now)
            except Exception as error:  # noqa: BLE001
                problems, host_judged = [Problem(f"backup:{host['name']}:malformed",
                                                 f"{host['name']}: Pharos backup data could not be judged "
                                                 f"({type(error).__name__}); its backups are unwatched.")], set()
            found.extend(problems)
            judged |= host_judged
        if not any(key.endswith(":age") for key in judged):
            found.append(Problem("backup:store", "pharosd store lists no backup observations; "
                                                 "fleet backups are currently unwatched."))
    current = {problem.key for problem in found}
    found += [Problem(key, text) for key, text in announced().items()
              if key.startswith("backup:") and key not in judged and key not in current]
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
