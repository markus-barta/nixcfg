"""Unit + engine-integration tests for the hsb1 Time Machine witness (OPS-226).

Pins the decisions that make it page (or not):

  * the exact 2026-09-22 state (2.5T quota, 1.94T data + 574G snapshots,
    no refquota) pages on refquota-unset AND headroom
  * the designed state (refquota 2.2T / quota 3T, 1.94T data, 200G snapshots)
    is clean
  * each threshold is its own stable key; a missing or stale sparsebundle is
    detected; unreadable zfs/zpool page rather than pass
  * through the real engine: one run does not page, the second does
"""

from __future__ import annotations

import importlib.util
import os
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

T = 1024**4
G = 1024**3


def load(replacements):
    relative = "hosts/hsb1/tm-watch.py"
    source = (ROOT / relative).read_text()
    for key, value in replacements.items():
        source = source.replace(f"@{key}@", value)
    assert "@ZFS_BIN@" not in source and "@NOTIFICATION_ENV@" not in source
    module = types.ModuleType("tm_watch")
    module.__dict__["__file__"] = str(ROOT / relative)
    exec(compile(source, str(ROOT / relative), "exec"), module.__dict__)
    return module


checks = load({
    "NOTIFICATION_ENV": "/nonexistent/notify.env",
    "ZFS_BIN": "/nonexistent/zfs",
    "ZPOOL_BIN": "/nonexistent/zpool",
})


def zfs_output(referenced, refquota, quota, snapshots):
    return "".join(
        f"{name}\t{value}\n"
        for name, value in (
            ("referenced", referenced), ("refquota", refquota),
            ("quota", quota), ("usedbysnapshots", snapshots),
        )
    )


def fake_run(zfs=None, zpool="53\n", fail=None):
    def run(argv, **kwargs):
        if fail and argv[0].endswith(fail):
            raise subprocess.CalledProcessError(1, argv)
        out = zfs if argv[0].endswith("zfs") else zpool
        return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")
    return run


class DatasetTest(unittest.TestCase):
    def dataset(self, output, bundle_age=3600.0):
        """Run check_dataset against a tmp dir holding one sparsebundle."""
        now = 1_800_000_000.0
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp, "mbp2607.sparsebundle")
            bundle.mkdir()
            if bundle_age is not None:
                os.utime(bundle, (now - bundle_age, now - bundle_age))
            else:
                bundle.rmdir()
            with patch.object(checks.subprocess, "run", fake_run(zfs=output)):
                return [p.key for p in checks.check_dataset("tm/markus", tmp, now)]

    def test_the_2026_09_22_incident_pages_twice(self):
        # quota 2.5T counted 1.94T data + 574G snapshots; no refquota at all.
        keys = self.dataset(zfs_output(int(1.94 * T), 0, int(2.5 * T), 574 * G))
        self.assertEqual(keys, ["tm:tm/markus:refquota", "tm:tm/markus:headroom"])

    def test_designed_state_is_clean(self):
        keys = self.dataset(zfs_output(int(1.94 * T), int(2.2 * T), int(3.2 * T), 200 * G))
        self.assertEqual(keys, [])

    def test_time_machine_at_its_own_cap_is_steady_state(self):
        # TM fills the volume it is given and thins itself; not a fault.
        keys = self.dataset(zfs_output(int(2.2 * T), int(2.2 * T), int(3.2 * T), 300 * G))
        self.assertEqual(keys, [])

    def test_snapshots_eating_the_gap_pages(self):
        # gap = 1T; 600G of snapshots is > half of it.
        keys = self.dataset(zfs_output(int(1.5 * T), int(2.2 * T), int(3.2 * T), 600 * G))
        self.assertEqual(keys, ["tm:tm/markus:snapshots"])

    def test_headroom_below_100g_pages(self):
        keys = self.dataset(zfs_output(int(2.2 * T), int(2.2 * T), int(3.2 * T), int(0.95 * T)))
        self.assertIn("tm:tm/markus:headroom", keys)

    def test_missing_and_stale_bundles(self):
        clean = zfs_output(1 * T, int(2.2 * T), 3 * T, 10 * G)
        self.assertEqual(self.dataset(clean, bundle_age=None), ["tm:tm/markus:bundle"])
        self.assertEqual(self.dataset(clean, bundle_age=80 * 3600), ["tm:tm/markus:stale"])
        self.assertEqual(self.dataset(clean, bundle_age=60 * 3600), [])

    def test_unreadable_zfs_pages(self):
        now = 1_800_000_000.0
        with patch.object(checks.subprocess, "run", fake_run(fail="zfs")):
            keys = [p.key for p in checks.check_dataset("tm/markus", "/nonexistent", now)]
        self.assertEqual(keys, ["tm:tm/markus:unreadable"])

    def test_texts_name_the_remedy(self):
        now = 1_800_000_000.0
        with tempfile.TemporaryDirectory() as tmp, patch.object(
            checks.subprocess, "run", fake_run(zfs=zfs_output(int(1.94 * T), 0, int(2.5 * T), 574 * G))
        ):
            problems = checks.check_dataset("tm/markus", tmp, now)
        texts = {p.key: p.text for p in problems}
        self.assertIn("zfs set refquota", texts["tm:tm/markus:refquota"])
        self.assertIn("Backup-Volume ist voll", texts["tm:tm/markus:headroom"])
        self.assertIn("data 1987G + snapshots 574G", texts["tm:tm/markus:headroom"])


class PoolAndSmbdTest(unittest.TestCase):
    def test_pool_capacity(self):
        with patch.object(checks.subprocess, "run", fake_run(zpool="53\n")):
            self.assertEqual(checks.check_pool(), [])
        with patch.object(checks.subprocess, "run", fake_run(zpool="91%\n")):
            self.assertEqual([p.key for p in checks.check_pool()], ["tm:pool"])
        with patch.object(checks.subprocess, "run", fake_run(fail="zpool")):
            self.assertEqual([p.key for p in checks.check_pool()], ["tm:pool"])

    def test_smbd_cgroup(self):
        with tempfile.TemporaryDirectory() as tmp:
            procs = Path(tmp, "cgroup.procs")
            procs.write_text("1234\n")
            with patch.object(checks, "SMBD_CGROUP_PROCS", str(procs)):
                self.assertEqual(checks.check_smbd(), [])
            procs.write_text("")
            with patch.object(checks, "SMBD_CGROUP_PROCS", str(procs)):
                self.assertEqual([p.key for p in checks.check_smbd()], ["tm:smbd"])
        with patch.object(checks, "SMBD_CGROUP_PROCS", "/nonexistent/cgroup.procs"):
            self.assertEqual([p.key for p in checks.check_smbd()], ["tm:smbd"])


class EngineIntegrationTest(unittest.TestCase):
    def test_confirms_then_pages_then_clears(self):
        sent: list[str] = []

        def sender(text, identifier):
            sent.append(text)
            return True

        broken = [checks.Problem("tm:tm/markus:headroom", "hsb1: tm/markus has only 0G below its 2560G quota")]
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
