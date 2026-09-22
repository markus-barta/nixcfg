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
faster than retention expires. This poller closes that gap — it is the one
component that may change state — and pages on everything else, through the
shared OPS-107 engine (confirm-before-alert, write-ahead delivery; same
Telegram target as tailnet-watch):

  * PRUNE            headroom under quota (quota − referenced − snapshots)
                     < 100G → destroy the oldest `autosnap_*` snapshots of
                     that dataset, oldest first, until ≥ 250G, always keeping
                     the newest. Snapshots are a rollback convenience; a
                     failed backup is the thing we exist to prevent.
  * tm:<ds>:caps     live refquota/quota differ from tm-caps.nix (unset, or
                     someone changed one side) — TM's cap and ZFS's disagree.
  * tm:<ds>:snapshots snapshot-held space > half the refquota→quota budget.
  * tm:<ds>:pruned   pruning happened (sustained on two runs = pages).
  * tm:<ds>:headroom still < 100G after pruning — nothing left to free;
                     raise quota now.
  * tm:<ds>:bundle   no sparsebundle (dataset not mounted / never backed up).
  * tm:<ds>:stale    newest completed backup (SnapshotHistory.plist inside
                     the bundle — real completion evidence, not a mtime)
                     older than STALE.
  * tm:pool          pool capacity > 85%.
  * tm:smbd          smbd has no process (found via its cgroup, whatever
                     slice NixOS puts it in).
  * tm:<ds>:unreadable / tm:pool  zfs / zpool failed — drive gone.

No "near refquota" check: Time Machine fills the volume it is given BY DESIGN
and thins when Samba reports it full, so referenced ≈ refquota is steady state.
Timer: 30 min; two-run confirmation ⇒ pages 30–60 min after onset; pruning
acts on the first run it is needed.
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
HEADROOM_MIN = 100 * GIB  # prune below this …
HEADROOM_TARGET = 250 * GIB  # … until at least this
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
    """Destroy the oldest autosnap_* until headroom ≥ HEADROOM_TARGET; keep the newest."""
    destroyed: list[str] = []
    candidates = autosnaps(dataset)
    while headroom(props) < HEADROOM_TARGET and len(candidates) > 1:
        victim = candidates.pop(0)
        run([ZFS, "destroy", victim])
        destroyed.append(victim)
        print(f"pruned {victim}")
        props = zfs_props(dataset)
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


def newest_completion(path: str, now: float) -> tuple[float | None, str]:
    """Age in seconds of the newest completed backup under `path`, and how we know.

    Time Machine rewrites com.apple.TimeMachine.SnapshotHistory.plist inside the
    sparsebundle when a backup completes (naive datetimes, UTC). Without it we
    fall back to band activity, which proves writing but not completion.
    """
    newest: float | None = None
    source = "no sparsebundle"
    try:
        bundles = [entry.path for entry in os.scandir(path)
                   if entry.name.endswith(".sparsebundle") and entry.is_dir(follow_symlinks=False)]
    except OSError:
        return None, source
    for bundle in bundles:
        try:
            with open(os.path.join(bundle, HISTORY_PLIST), "rb") as handle:
                history = plistlib.load(handle)
            stamps = [
                entry["com.apple.backupd.SnapshotCompletionDate"].replace(tzinfo=dt.timezone.utc).timestamp()
                for entry in history.get("Snapshots", [])
                if isinstance(entry.get("com.apple.backupd.SnapshotCompletionDate"), dt.datetime)
            ]
            if stamps:
                newest = max(stamps) if newest is None else max(newest, max(stamps))
                source = "last completed backup"
                continue
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            pass
        try:
            with os.scandir(os.path.join(bundle, "bands")) as bands:
                activity = max((b.stat(follow_symlinks=False).st_mtime for b in bands), default=None)
        except OSError:
            activity = None
        if activity is not None and (newest is None or activity > newest):
            newest, source = activity, "band activity only (no completion record)"
    return (None if newest is None else now - newest), source


def check_dataset(user: str, cap: dict, now: float) -> list[Problem]:
    dataset, path = cap["dataset"], cap["path"]
    try:
        props = zfs_props(dataset)
    except Exception as error:  # noqa: BLE001
        return [Problem(f"tm:{dataset}:unreadable",
                        f"hsb1: `zfs get {dataset}` failed ({type(error).__name__}) — tm pool not "
                        "imported or the USB drive is gone; Time Machine has no target.")]
    problems = check_caps(dataset, props, cap)
    budget = props["quota"] - props["refquota"]
    if budget > 0 and props["usedbysnapshots"] > SNAP_WARN * budget:
        problems.append(Problem(f"tm:{dataset}:snapshots",
                                f"hsb1: sanoid snapshots hold {gib(props['usedbysnapshots'])} of {dataset}'s "
                                f"{gib(budget)} snapshot budget (quota − refquota); tm-watch will prune "
                                "before ZFS refuses, but the bundle is churning hard — check "
                                f"`zfs list -t snapshot -r {dataset}` and the Mac."))
    if props["quota"] and headroom(props) < HEADROOM_MIN:
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
                                    f"`zfs set quota=…` now (tm-caps.nix)."))
    age, source = newest_completion(path, now)
    if age is None:
        problems.append(Problem(f"tm:{dataset}:bundle",
                                f"hsb1: no sparsebundle under {path} — dataset not mounted, or "
                                f"{user}'s Mac has never backed up here."))
    elif age > STALE_S:
        problems.append(Problem(f"tm:{dataset}:stale",
                                f"hsb1: {user}'s {source} is {age / 86400:.1f} days old — that Mac is "
                                "not backing up (away, share unreachable, or TM disabled). Check "
                                "System Settings → Time Machine on it."))
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
    now = time.time()
    found: list[Problem] = []
    for user, cap in sorted(CAPS.items()):
        found += check_dataset(user, cap, now)
    return found + check_pool() + check_smbd()


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f534 Time Machine (hsb1):"] + [f"• {item}" for item in announced]
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
