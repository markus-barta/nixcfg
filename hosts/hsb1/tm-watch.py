#!/usr/bin/env python3
"""Time Machine target witness — OPS-226.

2026-09-22 mbp2607 reported "Backup nicht abgeschlossen — Das Backup-Volume
ist voll." tm/markus had a 2.5T ZFS quota that counts snapshots (1.94T data +
574G held by sanoid) while Samba advertised the same 2.5T to Time Machine, so
TM believed 550G were free, never thinned, and ZFS refused the write. Nothing
paged; the Mac's notification was the alarm.

The design now pairs two caps per dataset (tm-caps.nix): refquota = TM's own
cap, Samba advertises a little less; quota = hard cap incl. snapshots. What
that cannot do by itself: TM deleting old backups does NOT free blocks a
sanoid snapshot still holds, so a churning bundle can eat the snapshot budget
faster than retention expires. This poller is the layer that closes that gap
— the one component here that may change state — and pages on everything
else through the shared OPS-107 engine (confirm-before-alert, write-ahead
delivery; same Telegram target as tailnet-watch).

Order of business on every run, and why:
  1. MAINTAIN — every dataset, independently, BEFORE any notification work:
     headroom under quota (quota − referenced − usedbysnapshots) < HEADROOM_MIN
     → destroy this dataset's `autosnap_*` snapshots oldest first until
     ≥ HEADROOM_TARGET. The newest is kept as a rollback point unless even
     that is not enough — a failed backup is the thing we exist to prevent,
     a rollback point is a convenience. A victim sanoid removed meanwhile is
     skipped, not fatal. Pruning never depends on Telegram: an undeliverable
     alert (engine retries pending delivery first) or a missing notification
     target must not stop capacity maintenance.
  2. REPORT through the engine:
     * tm:<ds>:caps        live refquota/quota differ from tm-caps.nix.
     * tm:<ds>:snapshots   snapshot-held space > half the refquota→quota budget.
     * tm:<ds>:pruned      pruning happened (sustained on two runs = pages).
     * tm:<ds>:headroom    still < HEADROOM_MIN with nothing left to prune —
                           raise quota now.
     * tm:<ds>:prune       a prune step failed.
     * tm:<ds>:bundle      no sparsebundle (not mounted / never backed up).
     * tm:<ds>:stale       no COMPLETED backup within STALE — read from
                           com.apple.TimeMachine.SnapshotHistory.plist inside
                           the bundle (TM rewrites it on completion). Band
                           activity without a completion is reported as such:
                           a Mac that keeps writing and never finishes is
                           exactly the failure we must not hide.
     * tm:<ds>:check       this dataset's check itself crashed (bad plist,
                           unexpected output) — isolated so the others still run.
     * tm:pool             pool capacity > 85%.
     * tm:smbd             smbd has no process (found via its cgroup, in
                           whatever slice NixOS puts it).
     * tm:<ds>:unreadable  zfs failed — drive gone / pool not imported.

Limits, stated honestly: pruning frees only blocks no remaining snapshot
references, so a bundle rewritten wholesale since the retained snapshot can
leave the headroom short (then `headroom` pages and quota must be raised);
and a write burst bigger than HEADROOM_MIN within one poll interval still
reaches ENOSPC. The 10-minute timer + 150G/400G bounds are sized so a Mac
writing flat out (~100 MB/s ≈ 60G per interval) stays inside them.

No "near refquota" check: Time Machine fills the volume it is given BY DESIGN
and thins when Samba reports it full, so referenced ≈ refquota is steady state.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import plistlib
import subprocess
import time

import engine
from engine import Problem

STATE_PATH = "/var/lib/tm-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
ZFS = "@ZFS_BIN@"
ZPOOL = "@ZPOOL_BIN@"
CAPS = json.loads('''@CAPS_JSON@''')
POOL = "tm"
SMBD_UNIT = "samba-smbd.service"
CGROUP_ROOT = "/sys/fs/cgroup/system.slice"
HISTORY_PLIST = "com.apple.TimeMachine.SnapshotHistory.plist"
TIMEOUT = 20
GIB = 1024**3
MIB = 1024**2

SNAP_WARN = 0.5  # usedbysnapshots / (quota - refquota)
HEADROOM_MIN = 150 * GIB  # prune below this …
HEADROOM_TARGET = 400 * GIB  # … until at least this
POOL_WARN = 85  # zpool capacity %
# A long weekend away must not page; a week of silence must.
STALE_S = 5 * 86400


def gib(value: int) -> str:
    return f"{value / GIB:.0f}G"


def run(argv: list[str]) -> str:
    completed = subprocess.run(  # noqa: S603 - literal binaries, substituted at build
        argv, capture_output=True, text=True, timeout=TIMEOUT, check=True,
    )
    return completed.stdout


def zfs_props(dataset: str) -> dict[str, int]:
    """referenced/refquota/quota/usedbysnapshots in bytes; unset caps are 0."""
    out = run([ZFS, "get", "-Hp", "-o", "property,value",
               "referenced,refquota,quota,usedbysnapshots", dataset])
    props: dict[str, int] = {}
    for line in out.splitlines():
        name, _, value = line.partition("\t")
        props[name.strip()] = int(value.strip() or 0)
    for key in ("referenced", "refquota", "quota", "usedbysnapshots"):
        if key not in props:
            raise ValueError(f"missing {key}")
    return props


def headroom(props: dict[str, int]) -> int:
    return props["quota"] - props["referenced"] - props["usedbysnapshots"]


def autosnaps(dataset: str) -> list[str]:
    """sanoid's snapshots of this dataset, oldest first."""
    out = run([ZFS, "list", "-Hp", "-t", "snapshot", "-o", "name", "-s", "creation", "-r", dataset])
    return [line.strip() for line in out.splitlines()
            if line.startswith(f"{dataset}@autosnap_")]


def prune(dataset: str, props: dict[str, int]) -> tuple[dict[str, int], list[str]]:
    """Destroy autosnap_* oldest first until headroom ≥ HEADROOM_TARGET.

    Pass 1 keeps the newest snapshot; pass 2 gives that up too if headroom is
    still below HEADROOM_MIN (blocks are only freed once no snapshot holds
    them, so the newest one can pin everything the older ones held). A victim
    that vanished (sanoid pruned it first) is skipped; any other failure raises.
    """
    destroyed: list[str] = []
    for keep in (1, 0):
        # Pass 1 prunes up to the comfortable target; pass 2 (the newest
        # snapshot, our rollback point) only if headroom is still critical.
        limit = HEADROOM_TARGET if keep else HEADROOM_MIN
        # List, then re-read accounting: sanoid may have pruned (or TM may
        # have thinned) between the caller's `zfs get` and now, and that
        # alone may have freed enough.
        candidates = autosnaps(dataset)
        props = zfs_props(dataset)
        while len(candidates) > keep and headroom(props) < limit:
            victim = candidates.pop(0)
            try:
                run([ZFS, "destroy", victim])
            except subprocess.CalledProcessError:
                if victim in autosnaps(dataset):
                    raise
                # sanoid got there first — its destroy freed space too, so
                # re-read before deciding whether anything else must go.
                props = zfs_props(dataset)
                continue
            destroyed.append(victim)
            print(f"pruned {victim}")
            props = zfs_props(dataset)
        if headroom(props) >= HEADROOM_MIN:
            break
    return props, destroyed


def check_caps(dataset: str, props: dict[str, int], cap: dict) -> list[Problem]:
    drift: list[str] = []
    for key, want_g in (("refquota", cap["refquotaG"]), ("quota", cap["quotaG"])):
        if abs(props[key] - want_g * GIB) > MIB:
            drift.append(f"{key} is {gib(props[key])}, declared {want_g}G")
    if not drift:
        return []
    return [Problem(f"tm:{dataset}:caps",
                    f"hsb1: {dataset} caps drift from tm-caps.nix ({'; '.join(drift)}) while Samba "
                    f"advertises {cap['maxSizeG']}G to Time Machine — ZFS and TM disagree about free "
                    f"space. Run: zfs set refquota={cap['refquotaG']}G quota={cap['quotaG']}G {dataset}")]


def completion_stamps(bundle: str) -> list[float]:
    """Completion times recorded by Time Machine; [] if none or unreadable."""
    stamps: list[float] = []
    try:
        with open(os.path.join(bundle, HISTORY_PLIST), "rb") as handle:
            history = plistlib.load(handle)
        if not isinstance(history, dict) or not isinstance(history.get("Snapshots"), list):
            return []
        for entry in history["Snapshots"]:
            if isinstance(entry, dict):
                when = entry.get("com.apple.backupd.SnapshotCompletionDate")
                if isinstance(when, dt.datetime):
                    stamps.append(when.replace(tzinfo=dt.timezone.utc).timestamp())
    except Exception:  # noqa: BLE001 - truncated/mid-rewrite/damaged/odd plist: no evidence
        return []
    return stamps


def band_activity(bundle: str) -> float | None:
    try:
        with os.scandir(os.path.join(bundle, "bands")) as bands:
            return max((b.stat(follow_symlinks=False).st_mtime for b in bands), default=None)
    except OSError:
        return None


def freshness(path: str, now: float) -> tuple[float | None, float | None, bool]:
    """(age of newest completed backup, age of newest band write, any bundle?)."""
    completed: float | None = None
    activity: float | None = None
    found = False
    try:
        entries = [e.path for e in os.scandir(path)
                   if e.name.endswith(".sparsebundle") and e.is_dir(follow_symlinks=False)]
    except OSError:
        return None, None, False
    for bundle in entries:
        found = True
        stamps = completion_stamps(bundle)
        if stamps:
            completed = max(stamps) if completed is None else max(completed, max(stamps))
        act = band_activity(bundle)
        if act is not None:
            activity = act if activity is None else max(activity, act)
    return (None if completed is None else now - completed,
            None if activity is None else now - activity, found)


def maintain(dataset: str, props: dict[str, int]) -> tuple[dict[str, int], list[Problem]]:
    """Free headroom under quota if needed; never blocks on anything else."""
    problems: list[Problem] = []
    if not props["quota"] or headroom(props) >= HEADROOM_MIN:
        return props, problems
    try:
        props, destroyed = prune(dataset, props)
    except Exception as error:  # noqa: BLE001
        destroyed = []
        problems.append(Problem(f"tm:{dataset}:prune",
                                f"hsb1: pruning {dataset} snapshots failed ({type(error).__name__}); "
                                "the next Time Machine write may fail. `zfs list -t snapshot -r "
                                f"{dataset}` and destroy the oldest autosnap_* by hand."))
    if destroyed:
        problems.append(Problem(f"tm:{dataset}:pruned",
                                f"hsb1: pruned {len(destroyed)} sanoid snapshot(s) of {dataset} to keep "
                                f"{gib(headroom(props))} under quota — Time Machine kept working. "
                                "Sustained pruning means the bundle churns faster than the budget; "
                                "raise quota (tm-caps.nix + zfs set)."))
    if headroom(props) < HEADROOM_MIN:
        problems.append(Problem(f"tm:{dataset}:headroom",
                                f"hsb1: {dataset} has only {gib(max(headroom(props), 0))} below its "
                                f"{gib(props['quota'])} quota (data {gib(props['referenced'])} + snapshots "
                                f"{gib(props['usedbysnapshots'])}) and nothing left to prune — the next "
                                "Time Machine write fails with 'Backup-Volume ist voll'. "
                                "`zfs set quota=…` now (tm-caps.nix)."))
    return props, problems


def check_dataset(user: str, cap: dict, now: float) -> list[Problem]:
    dataset, path = cap["dataset"], cap["path"]
    try:
        props = zfs_props(dataset)
    except Exception as error:  # noqa: BLE001
        return [Problem(f"tm:{dataset}:unreadable",
                        f"hsb1: `zfs get {dataset}` failed ({type(error).__name__}) — tm pool not "
                        "imported or the USB drive is gone; Time Machine has no target.")]
    props, problems = maintain(dataset, props)
    problems += check_caps(dataset, props, cap)
    budget = props["quota"] - props["refquota"]
    if budget > 0 and props["usedbysnapshots"] > SNAP_WARN * budget:
        problems.append(Problem(f"tm:{dataset}:snapshots",
                                f"hsb1: sanoid snapshots hold {gib(props['usedbysnapshots'])} of {dataset}'s "
                                f"{gib(budget)} snapshot budget (quota − refquota); tm-watch prunes "
                                "before ZFS refuses, but the bundle is churning hard — check "
                                f"`zfs list -t snapshot -r {dataset}` and the Mac."))
    # Freshness must never take the capacity findings above down with it.
    try:
        completed_age, activity_age, found = freshness(path, now)
    except Exception as error:  # noqa: BLE001
        problems.append(Problem(f"tm:{dataset}:check",
                                f"hsb1: tm-watch's freshness check of {dataset} crashed "
                                f"({type(error).__name__}) — fix the watcher; backup age is unknown."))
        return problems
    if not found:
        problems.append(Problem(f"tm:{dataset}:bundle",
                                f"hsb1: no sparsebundle under {path} — dataset not mounted, or "
                                f"{user}'s Mac has never backed up here."))
    elif completed_age is None or completed_age > STALE_S:
        since = ("no completed backup on record"
                 if completed_age is None else f"last completed backup {completed_age / 86400:.1f} days ago")
        writing = ("no band writes either" if activity_age is None
                   else f"bands last written {activity_age / 3600:.0f} h ago")
        problems.append(Problem(f"tm:{dataset}:stale",
                                f"hsb1: {user}'s Time Machine: {since}, {writing} — the Mac is away, "
                                "the share is unreachable, TM is off, or backups start and never "
                                "finish. Check System Settings → Time Machine on it."))
    return problems


def check_pool() -> list[Problem]:
    try:
        capacity = int(run([ZPOOL, "list", "-Hp", "-o", "capacity", POOL]).strip().rstrip("%"))
    except Exception as error:  # noqa: BLE001
        return [Problem("tm:pool", f"hsb1: `zpool list {POOL}` failed ({type(error).__name__}) — "
                        "the Time Machine drive is missing or the pool is not imported.")]
    if capacity > POOL_WARN:
        return [Problem("tm:pool", f"hsb1: pool {POOL} is {capacity}% full (>{POOL_WARN}%) — snapshot "
                        "budgets and quotas no longer fit; free space or shrink retention.")]
    return []


def unit_cgroup_procs(unit: str) -> str | None:
    """cgroup.procs of a system unit, whichever slice it sits in (≤ 2 levels)."""
    for root, dirs, _files in os.walk(CGROUP_ROOT):
        if os.path.basename(root) == unit:
            return os.path.join(root, "cgroup.procs")
        if root[len(CGROUP_ROOT):].count("/") >= 2:
            dirs[:] = []
    return None


def check_smbd() -> list[Problem]:
    procs = unit_cgroup_procs(SMBD_UNIT)
    if procs:
        try:
            with open(procs, encoding="utf-8") as handle:
                if any(line.strip() for line in handle):
                    return []
        except OSError:
            pass
    return [Problem("tm:smbd", "hsb1: smbd has no process — no Mac can reach its Time Machine share. "
                    "`systemctl status samba-smbd`.")]


def collect() -> list[Problem]:
    """Maintain + check every dataset; one dataset's crash never hides another's."""
    now = time.time()
    found: list[Problem] = []
    for user, cap in sorted(CAPS.items()):
        try:
            found += check_dataset(user, cap, now)
        except Exception as error:  # noqa: BLE001
            # Last resort: maintenance already ran inside check_dataset before
            # anything that can crash; only the report for this dataset is lost.
            found.append(Problem(f"tm:{cap['dataset']}:check",
                                 f"hsb1: tm-watch's own check of {cap['dataset']} crashed "
                                 f"({type(error).__name__}) — fix the watcher; the dataset is unwatched."))
    return found + check_pool() + check_smbd()


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f534 Time Machine (hsb1):"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["✅ Cleared — no longer failing:"] + [f"• {item}" for item in cleared]
    return "\n".join(lines)


def main() -> int:
    # Capacity maintenance first and unconditionally: the engine retries an
    # undelivered alert before it calls the check, and a missing/unusable
    # notification target must never stop pruning.
    problems = collect()
    print(f"tm-watch: {len(problems)} problem(s) after maintenance")
    target = engine.env_file_value(NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL")
    if not target:
        print("notification target missing")
        return engine.EXIT_UNDELIVERED
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError as error:
        print(f"notification target unusable: {error}")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(STATE_PATH, time.time(), lambda: problems, render, sender)


if __name__ == "__main__":
    raise SystemExit(main())
