"""Offline transaction shard coverage, determinism and sequential runner guards."""

from collections import Counter
from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import random
import subprocess
import sys
import unittest
from unittest import mock


SUITE = Path(__file__).with_name("test_hausnetz_cd.py")
spec = importlib.util.spec_from_file_location("t125_shard_contract", SUITE)
cd = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cd
spec.loader.exec_module(cd)


def assert_coverage(names, groups):
    actual = Counter(name for group in groups for name in group)
    expected = Counter(names)
    if not names or actual != expected or any(count != 1 for count in actual.values()):
        raise AssertionError("transaction shard coverage must include every case exactly once")


class TransactionShardTests(unittest.TestCase):
    def test_complete_coverage_and_must_fail_controls(self):
        names = cd.transaction_names()
        # Independent standard loader inventory catches omitted future classes.
        def flatten(suite):
            for item in suite:
                if isinstance(item, unittest.TestSuite):
                    yield from flatten(item)
                else:
                    yield item.id().removeprefix(cd.__name__ + ".")
        self.assertEqual(names, sorted(flatten(unittest.defaultTestLoader.loadTestsFromModule(cd))))
        groups = [cd.shard_names(n) for n in range(1, cd.TRANSACTION_SHARDS + 1)]
        assert_coverage(names, groups)
        for mode in ("missing", "duplicated"):
            broken = [list(group) for group in groups]
            if mode == "missing":
                broken[0].pop()
            else:
                broken[1].append(broken[0][0])
            with self.assertRaisesRegex(AssertionError, "exactly once"):
                assert_coverage(names, broken)
            print("must-fail shard control: " + mode + " case rejected", flush=True)
        # A newly discovered case cannot disappear behind a static assignment.
        class FutureCase(unittest.TestCase):
            def test_future(self):
                pass
        FutureCase.__module__ = cd.__name__
        with mock.patch.object(cd, "FutureCase", FutureCase, create=True):
            future = "FutureCase.test_future"
            self.assertIn(future, cd.transaction_names())
            groups = [cd.shard_names(n) for n in range(1, cd.TRANSACTION_SHARDS + 1)]
            assert_coverage(cd.transaction_names(), groups)

    def test_assignment_is_independent_of_order_environment_and_process(self):
        self.assertEqual(cd.TRANSACTION_SHARDS, 4)
        names = cd.transaction_names()
        expected = {name: cd.transaction_shard(name) for name in names}
        random.Random(764).shuffle(names)
        with mock.patch.dict(os.environ, {"CI": "true", "GITHUB_RUN_ATTEMPT": "99", "PYTHONHASHSEED": "764"}):
            self.assertEqual({name: cd.transaction_shard(name) for name in reversed(names)}, expected)
        # Pin the specified SHA256 rule independently of its implementation.
        import hashlib
        self.assertEqual(expected, {name: int(hashlib.sha256(name.encode()).hexdigest(), 16) % 4 + 1
                                    for name in names})
        script = ("import runpy; m=runpy.run_path(" + repr(str(SUITE)) + "); "
                  "print([(n,m['transaction_shard'](n)) for n in m['transaction_names']()])")
        outputs = [subprocess.check_output([sys.executable, "-B", "-c", script],
                   env=dict(os.environ, PYTHONHASHSEED=seed), text=True) for seed in ("1", "764")]
        self.assertEqual(outputs[0], outputs[1])

    def test_shard_runner_uses_one_sequential_unittest_process(self):
        for shard in range(1, cd.TRANSACTION_SHARDS + 1):
            names = cd.shard_names(shard)
            with mock.patch.object(cd.unittest.defaultTestLoader, "loadTestsFromNames") as load, \
                    mock.patch.object(cd.unittest, "TextTestRunner") as runner, \
                    mock.patch.object(cd, "ThreadPoolExecutor", side_effect=AssertionError("transactions must be sequential")), \
                    mock.patch.object(cd.subprocess, "run", side_effect=AssertionError("no child shards")), \
                    redirect_stdout(io.StringIO()):
                for success in (True, False):
                    runner.return_value.run.return_value.wasSuccessful.return_value = success
                    with self.assertRaises(SystemExit) as result:
                        cd.run_transaction_shard(shard)
                    self.assertEqual(result.exception.code, 0 if success else 1)
                    load.assert_called_with(names, module=cd)
                    runner.return_value.run.assert_called_with(load.return_value)
        for invalid in (0, cd.TRANSACTION_SHARDS + 1):
            with self.assertRaises(ValueError):
                cd.shard_names(invalid)


if __name__ == "__main__":
    unittest.main(verbosity=2)
