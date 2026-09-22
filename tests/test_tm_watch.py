"""Unit + engine-integration tests for the hsb1 Time Machine witness (OPS-226).

Pins the decisions that make it act, page, or stay quiet:

  * the exact 2026-09-22 state (2.5T quota, 1.94T data + 574G snapshots, no
    refquota) reports cap drift AND prunes snapshots rather than letting TM
    hit ENOSPC; with nothing left to prune it pages headroom
  * the declared state (tm-caps.nix values, TM sitting at its cap) is clean —
    Time Machine filling its volume is steady state, not a fault
  * every threshold has a stable key; freshness comes from the bundle's
    SnapshotHistory.plist (completion evidence), band mtimes only as fallback
  * smbd is found through its cgroup in whatever slice NixOS puts it
  * through the real engine: one run does not page, the second does
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("engine", ROOT / "modules/shared/fleet-alerts/engine.py")
engine = importlib.util.module_from_spec(SPEC)
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)

G = 1024**3
NOW = 1_800_000_000.0
CAPS = {
    "markus": {"dataset": "tm/markus", "path": "/srv/tm/markus", "refquotaG": 2253, "quotaG": 3277, "maxSizeG": 2200},
    "mailina": {"dataset": "tm/mailina", "path": "/srv/tm/mailina", "refquotaG": 1434, "quotaG": 2048, "maxSizeG": 1400},
}


def load(replacements):
    relative = "hosts/hsb1/tm-watch.py"
    source = (ROOT / relative).read_text()
    for key, value in replacements.items():
        source = source.replace(f"@{key}@", value)
    assert "@ZFS_BIN@" not in source and "@CAPS_JSON@" not in source
    module = types.ModuleType("tm_watch")
    module.__dict__["__file__"] = str(ROOT / relative)
    exec(compile(source, str(ROOT / relative), "exec"), module.__dict__)
    return module


checks = load({
    "NOTIFICATION_ENV": "/nonexistent/notify.env",
    "ZFS_BIN": "/nonexistent/zfs",
    "ZPOOL_BIN": "/nonexistent/zpool",
    "CAPS_JSON": json.dumps(CAPS),
})


class FakeZfs:
    """A dataset with snapshots; `zfs destroy` frees each snapshot's share."""

    def __init__(self, referenced, refquota, quota, snapshots, zpool="53\n", fail=None):
        self.referenced, self.refquota, self.quota = referenced, refquota, quota
        self.snapshots = list(snapshots)  # [(name, bytes_held)] oldest first
        self.zpool, self.fail = zpool, fail
        self.destroyed = []

    @property
    def usedbysnapshots(self):
        return sum(size for _, size in self.snapshots)

    def run(self, argv, **kwargs):
        if self.fail and argv[0].endswith(self.fail):
            raise subprocess.CalledProcessError(1, argv)
        if argv[0].endswith("zpool"):
            return subprocess.CompletedProcess(argv, 0, stdout=self.zpool, stderr="")
        if argv[1] == "get":
            out = (f"referenced\t{self.referenced}\nrefquota\t{self.refquota}\n"
                   f"quota\t{self.quota}\nusedbysnapshots\t{self.usedbysnapshots}\n")
        elif argv[1] == "list":
            out = "".join(f"{name}\n" for name, _ in self.snapshots)
        elif argv[1] == "destroy":
            name = argv[2]
            self.snapshots = [s for s in self.snapshots if s[0] != name]
            self.destroyed.append(name)
            out = ""
        else:
            raise AssertionError(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")


def snaps(dataset, count, each):
    return [(f"{dataset}@autosnap_2026-09-{10 + i:02d}_22:00:00_daily", each) for i in range(count)]


def write_history(bundle: Path, completed_at: float):
    stamp = dt.datetime.fromtimestamp(completed_at, dt.timezone.utc).replace(tzinfo=None)
    with open(bundle / checks.HISTORY_PLIST, "wb") as handle:
        plistlib.dump({"Snapshots": [
            {"com.apple.backupd.SnapshotCompletionDate": stamp - dt.timedelta(hours=2),
             "com.apple.backupd.SnapshotName": "older.backup"},
            {"com.apple.backupd.SnapshotCompletionDate": stamp,
             "com.apple.backupd.SnapshotName": "newest.backup"},
        ]}, handle)


class DatasetTest(unittest.TestCase):
    def run_dataset(self, zfs, completed_age=3600.0, with_bundle=True, with_history=True):
        with tempfile.TemporaryDirectory() as tmp:
            cap = dict(CAPS["markus"], path=tmp)
            if with_bundle:
                bundle = Path(tmp, "mbp2607.sparsebundle")
                (bundle / "bands").mkdir(parents=True)
                band = bundle / "bands" / "0"
                band.write_bytes(b"x")
                os.utime(band, (NOW - completed_age, NOW - completed_age))
                if with_history:
                    write_history(bundle, NOW - completed_age)
            with patch.object(checks.subprocess, "run", zfs.run):
                problems = checks.check_dataset("markus", cap, NOW)
        return {p.key: p.text for p in problems}

    def test_the_2026_09_22_incident_drifts_and_prunes_instead_of_failing(self):
        # quota 2.5T counted 1.94T data + 574G snapshots; no refquota at all.
        zfs = FakeZfs(int(1.94 * 1024 * G), 0, int(2.5 * 1024 * G), snaps("tm/markus", 14, 41 * G))
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:caps", found)
        self.assertIn("zfs set refquota=2253G quota=3277G tm/markus", found["tm:tm/markus:caps"])
        self.assertIn("tm:tm/markus:pruned", found)
        self.assertNotIn("tm:tm/markus:headroom", found)
        # Pruned oldest-first, only as many as needed to reach the 250G target.
        self.assertEqual(zfs.destroyed[0], "tm/markus@autosnap_2026-09-10_22:00:00_daily")
        self.assertGreaterEqual(zfs.quota - zfs.referenced - zfs.usedbysnapshots, 250 * G)
        self.assertLess(len(zfs.destroyed), 14)

    def test_declared_state_with_time_machine_at_its_cap_is_clean(self):
        zfs = FakeZfs(2253 * G, 2253 * G, 3277 * G, snaps("tm/markus", 7, 40 * G))
        self.assertEqual(self.run_dataset(zfs), {})
        self.assertEqual(zfs.destroyed, [])

    def test_snapshots_over_half_the_budget_page(self):
        zfs = FakeZfs(1500 * G, 2253 * G, 3277 * G, snaps("tm/markus", 7, 80 * G))  # 560G of 1024G
        self.assertEqual(list(self.run_dataset(zfs)), ["tm:tm/markus:snapshots"])

    def test_nothing_left_to_prune_pages_headroom(self):
        # One snapshot is always kept; data alone exceeds quota - 100G.
        zfs = FakeZfs(3200 * G, 2253 * G, 3277 * G, snaps("tm/markus", 2, 30 * G))
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:headroom", found)
        self.assertIn("Backup-Volume ist voll", found["tm:tm/markus:headroom"])
        self.assertEqual(len(zfs.destroyed), 1)
        self.assertEqual(len(zfs.snapshots), 1)

    def test_prune_failure_pages_and_does_not_hide_headroom(self):
        zfs = FakeZfs(3100 * G, 2253 * G, 3277 * G, snaps("tm/markus", 5, 40 * G))
        original = zfs.run

        def run(argv, **kwargs):
            if argv[1] == "destroy":
                raise subprocess.CalledProcessError(1, argv)
            return original(argv, **kwargs)

        zfs.run = run
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:prune", found)
        self.assertIn("tm:tm/markus:headroom", found)

    def test_freshness_uses_completion_record(self):
        clean = lambda: FakeZfs(1000 * G, 2253 * G, 3277 * G, snaps("tm/markus", 3, 10 * G))  # noqa: E731
        self.assertEqual(self.run_dataset(clean(), completed_age=4 * 86400), {})
        stale = self.run_dataset(clean(), completed_age=6 * 86400)
        self.assertEqual(list(stale), ["tm:tm/markus:stale"])
        self.assertIn("last completed backup is 6.0 days old", stale["tm:tm/markus:stale"])

    def test_band_activity_is_only_a_fallback(self):
        zfs = FakeZfs(1000 * G, 2253 * G, 3277 * G, snaps("tm/markus", 3, 10 * G))
        stale = self.run_dataset(zfs, completed_age=6 * 86400, with_history=False)
        self.assertIn("band activity only", stale["tm:tm/markus:stale"])

    def test_missing_bundle_pages(self):
        zfs = FakeZfs(1000 * G, 2253 * G, 3277 * G, snaps("tm/markus", 3, 10 * G))
        self.assertEqual(list(self.run_dataset(zfs, with_bundle=False)), ["tm:tm/markus:bundle"])

    def test_unreadable_zfs_pages(self):
        zfs = FakeZfs(0, 0, 0, [], fail="zfs")
        self.assertEqual(list(self.run_dataset(zfs)), ["tm:tm/markus:unreadable"])


class PoolAndSmbdTest(unittest.TestCase):
    def test_pool_capacity(self):
        for zpool, keys in (("53\n", []), ("91%\n", ["tm:pool"])):
            with patch.object(checks.subprocess, "run", FakeZfs(0, 0, 0, [], zpool=zpool).run):
                self.assertEqual([p.key for p in checks.check_pool()], keys)
        with patch.object(checks.subprocess, "run", FakeZfs(0, 0, 0, [], fail="zpool").run):
            self.assertEqual([p.key for p in checks.check_pool()], ["tm:pool"])

    def test_smbd_found_in_its_own_slice(self):
        with tempfile.TemporaryDirectory() as tmp:
            unit = Path(tmp, "system-samba.slice", "samba-smbd.service")
            unit.mkdir(parents=True)
            procs = unit / "cgroup.procs"
            procs.write_text("828840\n")
            with patch.object(checks, "CGROUP_ROOT", tmp):
                self.assertEqual(checks.check_smbd(), [])
                procs.write_text("")
                self.assertEqual([p.key for p in checks.check_smbd()], ["tm:smbd"])
        with patch.object(checks, "CGROUP_ROOT", "/nonexistent/cgroup"):
            self.assertEqual([p.key for p in checks.check_smbd()], ["tm:smbd"])


class EngineIntegrationTest(unittest.TestCase):
    def test_confirms_then_pages_then_clears(self):
        sent: list[str] = []

        def sender(text, identifier):
            sent.append(text)
            return True

        broken = [checks.Problem("tm:tm/markus:snapshots", "hsb1: sanoid snapshots hold 600G of tm/markus's 1024G snapshot budget")]
        with tempfile.TemporaryDirectory() as tmp:
            state = str(Path(tmp, "state.json"))
            self.assertEqual(engine.run_cycle(state, 1000, lambda: broken, checks.render, sender), engine.EXIT_PROBLEMS)
            self.assertEqual(sent, [])
            self.assertEqual(engine.run_cycle(state, 2800, lambda: broken, checks.render, sender), engine.EXIT_PROBLEMS)
            self.assertEqual(len(sent), 1)
            self.assertIn("\U0001f534 Time Machine (hsb1):", sent[0])
            self.assertEqual(engine.run_cycle(state, 4600, lambda: [], checks.render, sender), engine.EXIT_CLEAN)
            self.assertIn("✅ Cleared", sent[1])


if __name__ == "__main__":
    unittest.main()
