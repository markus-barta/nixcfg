#!/usr/bin/env python3
"""Time Machine target witness — OPS-226.

2026-09-22 mbp2607 reported "Backup nicht abgeschlossen — Das Backup-Volume
ist voll." tm/markus had a 2.5T ZFS quota that counts snapshots (1.94T data +
574G held by sanoid) while Samba advertised the same 2.5T to Time Machine, so
TM believed 550G were free, never thinned, and ZFS refused the write. Nothing
paged; the Mac's notification was the alarm.

The fix pairs two caps per dataset (tm-pool.nix): refquota = TM's own cap,
mirrored by Samba's `max size`; quota = hard cap incl. snapshots. This poller
(shared OPS-107 engine: confirm-before-alert, write-ahead delivery; same
Telegram target as tailnet-watch) pages BEFORE the design can fail again:

  * tm:<ds>:refquota   refquota unset — the imperative `zfs set` in
                       tm-pool.nix was not run; TM's cap and ZFS's disagree.
  * tm:<ds>:snapshots  snapshot-held space > half the refquota→quota gap.
                       (No "near refquota" check: Time Machine fills the
                       volume it is given BY DESIGN and thins when Samba
                       reports it full, so referenced ≈ refquota is the
                       steady state, not a fault.)
  * tm:<ds>:headroom   quota − (data + snapshots) < 100G — the next TM write
                       fails; raise quota now.
  * tm:<ds>:bundle     no sparsebundle at all (dataset not mounted, or never
                       backed up), or the newest one older than STALE — the
                       Mac has stopped backing up.
  * tm:pool            pool capacity > 85%.
  * tm:smbd            smbd has no process — no Mac can reach its share.
  * tm:<ds>:unreadable `zfs get` failed — pool not imported / drive absent.

Timer: 30 min; two-run confirmation ⇒ pages 30–60 min after onset.
"""

from __future__ import annotations

import os
import subprocess
import time

import engine
from engine import Problem

STATE_PATH = "/var/lib/tm-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
ZFS = "@ZFS_BIN@"
ZPOOL = "@ZPOOL_BIN@"
POOL = "tm"
DATASETS = {
    "tm/markus": "/srv/tm/markus",
    "tm/mailina": "/srv/tm/mailina",
}
SMBD_CGROUP_PROCS = "/sys/fs/cgroup/system.slice/samba-smbd.service/cgroup.procs"
TIMEOUT = 20
GIB = 1024**3

SNAP_WARN = 0.5  # usedbysnapshots / (quota - refquota)
HEADROOM_MIN = 100 * GIB  # quota - (referenced + usedbysnapshots)
POOL_WARN = 85  # zpool capacity %
# A Mac away for a long weekend must not page; a week of silence must.
STALE_S = 72 * 3600


def gib(value: int) -> str:
    return f"{value / GIB:.0f}G"


def zfs_props(dataset: str) -> dict[str, int]:
    """referenced/refquota/quota/usedbysnapshots in bytes; unset caps are 0."""
    completed = subprocess.run(  # noqa: S603 - literal argv, substituted at build
        [ZFS, "get", "-Hp", "-o", "property,value",
         "referenced,refquota,quota,usedbysnapshots", dataset],
        capture_output=True, text=True, timeout=TIMEOUT, check=True,
    )
    props: dict[str, int] = {}
    for line in completed.stdout.splitlines():
        name, _, value = line.partition("\t")
        props[name.strip()] = int(value.strip() or 0)
    for key in ("referenced", "refquota", "quota", "usedbysnapshots"):
        if key not in props:
            raise ValueError(f"missing {key}")
    return props


def newest_bundle_age(path: str, now: float) -> float | None:
    """Seconds since the newest *.sparsebundle changed; None if there is none."""
    newest: float | None = None
    try:
        with os.scandir(path) as entries:
            for entry in entries:
                if entry.name.endswith(".sparsebundle") and entry.is_dir(follow_symlinks=False):
                    stamp = entry.stat(follow_symlinks=False).st_mtime
                    newest = stamp if newest is None else max(newest, stamp)
    except OSError:
        return None
    return None if newest is None else now - newest


def check_dataset(dataset: str, path: str, now: float) -> list[Problem]:
    user = dataset.rsplit("/", 1)[-1]
    try:
        props = zfs_props(dataset)
    except Exception as error:  # noqa: BLE001
        return [Problem(f"tm:{dataset}:unreadable",
                        f"hsb1: `zfs get {dataset}` failed ({type(error).__name__}) — tm pool not "
                        "imported or the USB drive is gone; Time Machine has no target.")]
    referenced, refquota = props["referenced"], props["refquota"]
    quota, snapshots = props["quota"], props["usedbysnapshots"]
    problems: list[Problem] = []

    if refquota == 0:
        problems.append(Problem(f"tm:{dataset}:refquota",
                                f"hsb1: {dataset} has no refquota — run the `zfs set refquota=… quota=…` "
                                "from tm-pool.nix; until then Time Machine's cap and ZFS's disagree "
                                "and the volume can fill silently."))
    else:
        if quota > refquota and snapshots > SNAP_WARN * (quota - refquota):
            problems.append(Problem(f"tm:{dataset}:snapshots",
                                    f"hsb1: sanoid snapshots hold {gib(snapshots)} of {dataset}'s "
                                    f"{gib(quota - refquota)} snapshot budget (quota − refquota). "
                                    "Check `zfs list -t snapshot -r " + dataset + "`; shorten sanoid "
                                    "retention or raise quota."))
    if quota:
        headroom = quota - (referenced + snapshots)
        if headroom < HEADROOM_MIN:
            problems.append(Problem(f"tm:{dataset}:headroom",
                                    f"hsb1: {dataset} has only {gib(max(headroom, 0))} below its "
                                    f"{gib(quota)} quota (data {gib(referenced)} + snapshots "
                                    f"{gib(snapshots)}) — the next Time Machine write fails with "
                                    "'Backup-Volume ist voll'. `zfs set quota=…` now (tm-pool.nix)."))

    age = newest_bundle_age(path, now)
    if age is None:
        problems.append(Problem(f"tm:{dataset}:bundle",
                                f"hsb1: no sparsebundle under {path} — dataset not mounted, or "
                                f"{user}'s Mac has never backed up here."))
    elif age > STALE_S:
        problems.append(Problem(f"tm:{dataset}:stale",
                                f"hsb1: {user}'s Time Machine bundle last changed {age / 3600:.0f} h "
                                "ago — that Mac is not backing up (asleep for days, share unreachable, "
                                "or TM disabled). Check System Settings → Time Machine on it."))
    return problems


def check_pool() -> list[Problem]:
    try:
        completed = subprocess.run(  # noqa: S603
            [ZPOOL, "list", "-Hp", "-o", "capacity", POOL],
            capture_output=True, text=True, timeout=TIMEOUT, check=True,
        )
        capacity = int(completed.stdout.strip().rstrip("%"))
    except Exception as error:  # noqa: BLE001
        return [Problem("tm:pool", f"hsb1: `zpool list {POOL}` failed ({type(error).__name__}) — "
                        "the Time Machine drive is missing or the pool is not imported.")]
    if capacity > POOL_WARN:
        return [Problem("tm:pool", f"hsb1: pool {POOL} is {capacity}% full (>{POOL_WARN}%) — snapshot "
                        "budgets and quotas no longer fit; free space or shrink retention.")]
    return []


def check_smbd() -> list[Problem]:
    try:
        with open(SMBD_CGROUP_PROCS, encoding="utf-8") as handle:
            if any(line.strip() for line in handle):
                return []
    except OSError:
        pass
    return [Problem("tm:smbd", "hsb1: smbd has no process — no Mac can reach its Time Machine share. "
                    "`systemctl status samba-smbd`.")]


def collect() -> list[Problem]:
    now = time.time()
    found: list[Problem] = []
    for dataset, path in DATASETS.items():
        found += check_dataset(dataset, path, now)
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
