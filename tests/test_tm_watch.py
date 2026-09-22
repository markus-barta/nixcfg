"""Unit + engine-integration tests for the hsb1 Time Machine witness (OPS-226).

Pins the decisions that make it act, page, or stay quiet:

  * the exact 2026-09-22 state (2.5T quota, 1.94T data + 574G snapshots, no
    refquota) reports cap drift AND prunes snapshots rather than letting TM
    hit ENOSPC; with nothing left to prune it pages headroom
  * pruning keeps the newest snapshot unless even that is not enough, skips a
    victim sanoid removed first, and runs BEFORE and independently of any
    notification (missing target, undelivered pending alert)
  * the declared state (tm-caps.nix values, TM sitting at its cap) is clean —
    Time Machine filling its volume is steady state, not a fault
  * freshness is completion evidence from SnapshotHistory.plist; band writes
    without a completion are reported, never treated as healthy; a damaged
    plist is "no evidence", never a crash; a crashing check is isolated
  * smbd is found through its cgroup in whatever slice NixOS puts it
  * through the real engine: one run does not page, the second does
"""

from __future__ import annotations

import contextlib
import datetime as dt
import importlib.util
import io
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
    """A dataset with snapshots; `zfs destroy` frees the bytes a snapshot holds
    exclusively; `pinned` bytes stay allocated while ANY snapshot remains."""

    def __init__(self, referenced, refquota, quota, snapshots, zpool="53\n", fail=None, pinned=0):
        self.referenced, self.refquota, self.quota = referenced, refquota, quota
        self.snapshots = list(snapshots)  # [(name, bytes_held_exclusively)] oldest first
        self.zpool, self.fail, self.pinned = zpool, fail, pinned
        self.destroyed = []
        self.vanish = set()  # names sanoid removes before we get to them

    @property
    def usedbysnapshots(self):
        shared = self.pinned if self.snapshots else 0
        return sum(size for _, size in self.snapshots) + shared

    def headroom(self):
        return self.quota - self.referenced - self.usedbysnapshots

    def run(self, argv, **kwargs):
        if self.fail and argv[0].endswith(self.fail):
            raise subprocess.CalledProcessError(1, argv)
        if argv[0].endswith("zpool"):
            return subprocess.CompletedProcess(argv, 0, stdout=self.zpool, stderr="")
        if argv[1] == "get":
            out = (f"referenced\t{self.referenced}\nrefquota\t{self.refquota}\n"
                   f"quota\t{self.quota}\nusedbysnapshots\t{self.usedbysnapshots}\n")
        elif argv[1] == "list":
            self.snapshots = [s for s in self.snapshots if s[0] not in self.vanish]
            out = "".join(f"{name}\n" for name, _ in self.snapshots)
        elif argv[1] == "destroy":
            name = argv[2]
            if name in self.vanish or name not in [s[0] for s in self.snapshots]:
                raise subprocess.CalledProcessError(1, argv)
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


def clean_zfs():
    return FakeZfs(1000 * G, 2253 * G, 3277 * G, snaps("tm/markus", 3, 10 * G))


class DatasetTest(unittest.TestCase):
    def run_dataset(self, zfs, completed_age=3600.0, band_age=None, with_bundle=True, history="ok"):
        band_age = completed_age if band_age is None else band_age
        with tempfile.TemporaryDirectory() as tmp:
            cap = dict(CAPS["markus"], path=tmp)
            if with_bundle:
                bundle = Path(tmp, "mbp2607.sparsebundle")
                (bundle / "bands").mkdir(parents=True)
                band = bundle / "bands" / "0"
                band.write_bytes(b"x")
                os.utime(band, (NOW - band_age, NOW - band_age))
                if history == "ok":
                    write_history(bundle, NOW - completed_age)
                elif history == "truncated":
                    (bundle / checks.HISTORY_PLIST).write_bytes(b'<?xml version="1.0"?><plist><dict><key>Snap')
                elif history == "wrong-shape":
                    with open(bundle / checks.HISTORY_PLIST, "wb") as handle:
                        plistlib.dump(["not", "a", "dict"], handle)
            with patch.object(checks.subprocess, "run", zfs.run), contextlib.redirect_stdout(io.StringIO()):
                problems = checks.check_dataset("markus", cap, NOW)
        return {p.key: p.text for p in problems}

    def test_the_2026_09_22_incident_drifts_and_prunes_instead_of_failing(self):
        zfs = FakeZfs(int(1.94 * 1024 * G), 0, int(2.5 * 1024 * G), snaps("tm/markus", 14, 41 * G))
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:caps", found)
        self.assertIn("zfs set refquota=2253G quota=3277G tm/markus", found["tm:tm/markus:caps"])
        self.assertIn("tm:tm/markus:pruned", found)
        self.assertNotIn("tm:tm/markus:headroom", found)
        self.assertEqual(zfs.destroyed[0], "tm/markus@autosnap_2026-09-10_22:00:00_daily")
        self.assertGreaterEqual(zfs.headroom(), 400 * G)
        self.assertLess(len(zfs.destroyed), 14)
        self.assertGreaterEqual(len(zfs.snapshots), 1)

    def test_declared_state_with_time_machine_at_its_cap_is_clean(self):
        zfs = FakeZfs(2253 * G, 2253 * G, 3277 * G, snaps("tm/markus", 7, 40 * G))
        self.assertEqual(self.run_dataset(zfs), {})
        self.assertEqual(zfs.destroyed, [])

    def test_snapshots_over_half_the_budget_page(self):
        zfs = FakeZfs(1500 * G, 2253 * G, 3277 * G, snaps("tm/markus", 7, 80 * G))  # 560G of 1024G
        self.assertEqual(list(self.run_dataset(zfs)), ["tm:tm/markus:snapshots"])

    def test_newest_snapshot_is_given_up_when_it_pins_the_blocks(self):
        # 950G pinned by every snapshot: pass 1 (keep newest) leaves 117G < 150G,
        # so the newest goes too rather than letting the next write fail.
        zfs = FakeZfs(2200 * G, 2253 * G, 3277 * G, snaps("tm/markus", 4, 10 * G), pinned=950 * G)
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:pruned", found)
        self.assertNotIn("tm:tm/markus:headroom", found)
        self.assertEqual(zfs.snapshots, [])

    def test_nothing_left_to_prune_pages_headroom(self):
        zfs = FakeZfs(3200 * G, 2253 * G, 3277 * G, snaps("tm/markus", 2, 30 * G))
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:headroom", found)
        self.assertIn("Backup-Volume ist voll", found["tm:tm/markus:headroom"])
        self.assertEqual(zfs.snapshots, [])

    def test_victim_removed_by_sanoid_is_skipped(self):
        zfs = FakeZfs(2900 * G, 2253 * G, 3277 * G, snaps("tm/markus", 5, 100 * G))
        zfs.vanish.add("tm/markus@autosnap_2026-09-10_22:00:00_daily")
        found = self.run_dataset(zfs)
        self.assertIn("tm:tm/markus:pruned", found)
        self.assertNotIn("tm:tm/markus:prune", found)
        self.assertNotIn("tm/markus@autosnap_2026-09-10_22:00:00_daily", zfs.destroyed)

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
        self.assertEqual(self.run_dataset(clean_zfs(), completed_age=4 * 86400), {})
        stale = self.run_dataset(clean_zfs(), completed_age=6 * 86400)
        self.assertEqual(list(stale), ["tm:tm/markus:stale"])
        self.assertIn("last completed backup 6.0 days ago", stale["tm:tm/markus:stale"])

    def test_writing_without_completing_is_reported_not_hidden(self):
        found = self.run_dataset(clean_zfs(), completed_age=6 * 86400, band_age=600.0)
        self.assertIn("bands last written 0 h ago", found["tm:tm/markus:stale"])
        no_record = self.run_dataset(clean_zfs(), band_age=600.0, history="none")
        self.assertIn("no completed backup on record", no_record["tm:tm/markus:stale"])

    def test_damaged_plist_is_no_evidence_not_a_crash(self):
        for shape in ("truncated", "wrong-shape"):
            with self.subTest(shape=shape):
                found = self.run_dataset(clean_zfs(), band_age=600.0, history=shape)
                self.assertEqual(list(found), ["tm:tm/markus:stale"])

    def test_missing_bundle_pages(self):
        self.assertEqual(list(self.run_dataset(clean_zfs(), with_bundle=False)), ["tm:tm/markus:bundle"])

    def test_unreadable_zfs_pages(self):
        self.assertEqual(list(self.run_dataset(FakeZfs(0, 0, 0, [], fail="zfs"))), ["tm:tm/markus:unreadable"])


class CollectTest(unittest.TestCase):
    def test_one_crashing_dataset_does_not_hide_the_other(self):
        calls = []

        def check_dataset(user, cap, now):
            calls.append(user)
            if user == "mailina":
                raise RuntimeError("boom")
            return []

        with patch.object(checks, "check_dataset", check_dataset), \
                patch.object(checks, "check_pool", lambda: []), patch.object(checks, "check_smbd", lambda: []):
            keys = [p.key for p in checks.collect()]
        self.assertEqual(calls, ["mailina", "markus"])
        self.assertEqual(keys, ["tm:tm/mailina:check"])

    def test_maintenance_runs_before_and_without_notification(self):
        pruned = []
        with patch.object(checks, "collect", lambda: pruned.append("ran") or []), \
                patch.object(checks.engine, "env_file_value", lambda *_: ""), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
        self.assertEqual(pruned, ["ran"], "collect (and so pruning) must run even with no target")

    def test_maintenance_runs_even_when_a_pending_alert_is_undeliverable(self):
        ran = []
        with tempfile.TemporaryDirectory() as tmp:
            state = str(Path(tmp, "state.json"))
            engine.atomic_write_state(state, {"seen": {}, "pending": {"event_id": "x", "text": "old alert",
                                                                       "next_state": {"seen": {}, "pending": None}}})
            with patch.object(checks, "STATE_PATH", state), \
                    patch.object(checks, "collect", lambda: ran.append("ran") or []), \
                    patch.object(checks.engine, "env_file_value", lambda *_: "telegram://t@telegram?chats=1"), \
                    patch.object(checks.engine, "shoutrrr_telegram_sender", lambda url: (lambda text, ident: False)), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
        self.assertEqual(ran, ["ran"])


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
            self.assertEqual(engine.run_cycle(state, 1600, lambda: broken, checks.render, sender), engine.EXIT_PROBLEMS)
            self.assertEqual(len(sent), 1)
            self.assertIn("\U0001f534 Time Machine (hsb1):", sent[0])
            self.assertEqual(engine.run_cycle(state, 2200, lambda: [], checks.render, sender), engine.EXIT_CLEAN)
            self.assertIn("✅ Cleared", sent[1])


if __name__ == "__main__":
    unittest.main()
