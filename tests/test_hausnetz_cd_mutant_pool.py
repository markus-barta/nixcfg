"""The real T125 --mutants entry point must fail closed across worker futures."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
import importlib.util
import inspect
import io
from pathlib import Path
import subprocess
import sys
import threading
import unittest
from unittest import mock


SUITE = Path(__file__).with_name("test_hausnetz_cd.py")


def load_suite():
    spec = importlib.util.spec_from_file_location("t125_pool_controls", SUITE)
    suite = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(suite)
    return suite


def negative_control(mode):
    suite = load_suite()
    real_check = suite.check_mutant
    real_mutants = suite.mutants
    real_run = subprocess.run

    def injected(case):
        label, filename, edits, test = case
        if label == "G1 flake lines":  # Collect successful futures before failure.
            if mode == "survivor":
                case = (label, filename, [(before, before) for before, _after in edits], test)
            elif mode == "crash":
                raise RuntimeError("OPS764 deliberate worker crash")
            elif mode == "invalid":
                case = (label, filename, [(edits[0][0], "OPS764 invalid Python !!!")], test)
            elif mode != "timeout":
                raise AssertionError("unknown negative control")
        return real_check(case)

    def capped_run(command, **kwargs):
        if mode == "timeout" and command[-1] == "TestCD.test_g1_same_file_extra_line":
            if kwargs.get("timeout") != 120:
                raise AssertionError("check_mutant must pass timeout=120")
            # Exercise the real check_mutant path and a real expired subprocess,
            # shortening only the fixture cap after checking the production cap.
            return real_run([sys.executable, "-c", "import time; time.sleep(60)"],
                            timeout=0.05, check=False)
        return real_run(command, **kwargs)

    # Inject at the per-case boundary, independent of map/submit/as_completed.
    # Keep the real CLI dispatcher, workers, source copies and result handling.
    with mock.patch.object(suite, "check_mutant", side_effect=injected), \
            mock.patch.object(suite, "mutants", side_effect=lambda: real_mutants(only="G1 ")), \
            mock.patch.object(subprocess, "run", side_effect=capped_run), \
            mock.patch.object(sys, "argv", [str(SUITE), "--mutants"]):
        suite.main()


class MutantPoolTests(unittest.TestCase):
    def test_negative_controls_exit_nonzero(self):
        for mode, evidence in (
            ("survivor", "SURVIVED guard-removal mutant: G1 flake lines"),
            ("crash", "RuntimeError: OPS764 deliberate worker crash"),
            ("timeout", "subprocess.TimeoutExpired:"),
            ("invalid", "Invalid mutant run: G1 flake lines"),
        ):
            with self.subTest(mode=mode):
                result = subprocess.run([sys.executable, "-B", __file__, "--negative-control", mode],
                                        capture_output=True, text=True, timeout=60, check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(evidence, result.stderr)
                self.assertIn("must-fail mutant killed: G1 extra file", result.stdout)
                self.assertIn("must-fail mutant killed: G1 executable mode change", result.stdout)
                self.assertNotIn("guard-removal mutants killed", result.stdout)
                print("must-fail pool control: " + mode + " exited " + str(result.returncode), flush=True)

    def assert_mutant_cap(self, suite, check):
        real_run = subprocess.run
        def capped_run(command, **kwargs):
            self.assertEqual(kwargs.get("timeout"), 120, "check_mutant must pass timeout=120")
            return real_run([sys.executable, "-c", "import time; time.sleep(60)"],
                            timeout=0.05, check=False)
        with mock.patch.object(suite.subprocess, "run", side_effect=capped_run) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                check(("timeout fixture", "common.py", [], "test_g1_extra_file"))
            run.assert_called_once()

    def test_per_mutant_cap_and_expiration(self):
        suite = load_suite()
        self.assertEqual(suite.MUTANT_TIMEOUT_SECONDS, 120)
        self.assert_mutant_cap(suite, suite.check_mutant)
        # Demonstrate that deleting or raising the real subprocess cap is red.
        original = inspect.getsource(suite.check_mutant)
        for replacement in ("", "timeout=121, "):
            with self.subTest(replacement=replacement):
                self.assertEqual(original.count("timeout=MUTANT_TIMEOUT_SECONDS, "), 1)
                namespace = dict(suite.__dict__)
                exec(compile(original.replace("timeout=MUTANT_TIMEOUT_SECONDS, ", replacement), str(SUITE), "exec"), namespace)
                with self.assertRaisesRegex(AssertionError, "check_mutant must pass timeout=120"):
                    self.assert_mutant_cap(suite, namespace["check_mutant"])
                print("must-fail mutant killed: per-mutant cap " + ("removed" if not replacement else "raised"), flush=True)

    def test_selection_and_order(self):
        suite = load_suite()
        selections = []
        completed = []
        done = [threading.Event() for _ in range(4)]
        labels = ["G1 flake lines", "G1 lock leaves", "G1 doc/test lines", "G1 running baseline"]
        real_pool = ThreadPoolExecutor

        class RecordingPool(real_pool):
            def __init__(self, max_workers):
                self.assert_workers(max_workers)
                super().__init__(max_workers=max_workers)

            @staticmethod
            def assert_workers(max_workers):
                if max_workers != 4:
                    raise AssertionError("mutants must use four bounded workers")

            def map(self, check, cases):
                selections.append([case[0] for case in cases])
                return super().map(check, cases)

        def reversed_completion(case):
            index = labels.index(case[0])
            if index + 1 < len(labels) and not done[index + 1].wait(5):
                raise AssertionError("four workers did not make progress")
            completed.append(case[0])
            done[index].set()
            return case[0]

        with mock.patch.object(suite, "ThreadPoolExecutor", RecordingPool), \
                mock.patch.object(suite, "check_mutant", side_effect=reversed_completion), \
                redirect_stdout(io.StringIO()) as out:
            suite.mutants(only="G1 ", start_after="G1 executable mode change")
        self.assertEqual(selections, [labels])
        self.assertEqual(completed, list(reversed(labels)))
        self.assertEqual(out.getvalue().splitlines(), [
            *("must-fail mutant killed: " + label for label in labels),
            "T125: 4 pooled mutants killed; 0 timing-window mutants next",
            "T125: 4 guard-removal mutants killed",
        ])

    def test_timing_window_mutants_run_after_pool(self):
        suite = load_suite()
        expected = {
            "test_once_requires_both_flags_and_refuses_live_pending",
            "test_acceptance_orphan_pipe_timeout_rolls_back",
            "test_timeout_pipe_from_escaped_descendant_is_bounded",
            "test_controller_term_and_int_kill_descendant_group",
            "test_release_detached_from_controller_timeout",
        }
        self.assertEqual(suite.TIMING_WINDOW_TARGETS, expected)
        pooled, sequential, finished = [], [], threading.Event()

        class RecordingPool(ThreadPoolExecutor):
            def map(self, check, cases):
                pooled.extend(cases)
                return super().map(check, cases)

            def __exit__(self, *args):
                result = super().__exit__(*args)
                finished.set()
                return result

        def record(case):
            if case[3] in expected:
                self.assertTrue(finished.is_set(), "timing windows must start after pool shutdown")
                self.assertEqual(threading.current_thread(), threading.main_thread())
                sequential.append(case)
            else:
                self.assertFalse(finished.is_set())
            return case[0]

        with mock.patch.object(suite, "ThreadPoolExecutor", RecordingPool), \
                mock.patch.object(suite, "check_mutant", side_effect=record), \
                redirect_stdout(io.StringIO()) as out:
            suite.mutants()
        self.assertTrue(pooled)
        self.assertFalse(any(case[3] in expected for case in pooled))
        # One named target has no mutant today; future mutants inherit the rule.
        self.assertEqual({case[3] for case in sequential}, expected - {"test_acceptance_orphan_pipe_timeout_rolls_back"})
        self.assertEqual(len(sequential), 5)
        labels = [case[0] for case in pooled + sequential]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertEqual(len(labels), 276)
        self.assertIn("T125: 276 guard-removal mutants killed", out.getvalue())
        for failure in (RuntimeError("sequential crash"), subprocess.TimeoutExpired("fixture", 45)):
            def fail_sequential(case):
                if case[3] in expected:
                    raise failure
                return case[0]
            with self.subTest(failure=failure), mock.patch.object(suite, "check_mutant", side_effect=fail_sequential), \
                    redirect_stdout(io.StringIO()) as out:
                with self.assertRaises(type(failure)):
                    suite.mutants()
                self.assertNotIn("guard-removal mutants killed", out.getvalue())


if __name__ == "__main__":
    if sys.argv[1:2] == ["--negative-control"]:
        negative_control(sys.argv[2])
    else:
        unittest.main(verbosity=2)
