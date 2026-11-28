"""The real T125 --mutants entry point must fail closed across worker futures."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import runpy
import subprocess
import sys
import threading
import unittest
from unittest import mock


SUITE = Path(__file__).with_name("test_hausnetz_cd.py")


def negative_control(mode):
    # Inject through the executor boundary, leaving the CLI, source copies,
    # behavioral assertions, result collection and exception handling real.
    class InjectedPool(ThreadPoolExecutor):
        def __init__(self, max_workers):
            if max_workers != 4:
                raise AssertionError("mutants must use four bounded workers")
            super().__init__(max_workers=max_workers)

        def map(self, check, cases):
            selected = list(cases)[:3]
            target = selected[-1][0]  # Collect successful futures before failure.

            def injected(case):
                if case[0] == target:
                    label, filename, edits, test = case
                    if mode == "survivor":
                        case = (label, filename, [(before, before) for before, _after in edits], test)
                    elif mode == "crash":
                        raise RuntimeError("OPS764 deliberate worker crash")
                    elif mode == "timeout":
                        # A real timed-out process, with a short fixture budget;
                        # the production per-mutant cap remains 45 seconds.
                        subprocess.run([sys.executable, "-c", "import time; time.sleep(60)"],
                                       timeout=0.05, check=False)
                        raise AssertionError("timeout fixture unexpectedly returned")
                    elif mode == "invalid":
                        case = (label, filename, [(edits[0][0], "OPS764 invalid Python !!!")], test)
                    else:
                        raise AssertionError("unknown negative control")
                return check(case)

            return super().map(injected, selected)

    with mock.patch("concurrent.futures.ThreadPoolExecutor", InjectedPool), \
            mock.patch.object(sys, "argv", [str(SUITE), "--mutants"]):
        runpy.run_path(str(SUITE), run_name="__main__")


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

    def test_selection_and_order(self):
        spec = importlib.util.spec_from_file_location("t125_pool_selection", SUITE)
        suite = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(suite)
        selections = []
        completed = []

        class RecordingPool(ThreadPoolExecutor):
            def map(self, check, cases):
                selections.append([case[0] for case in cases])
                # Force completion in reverse order without timing sleeps.
                done = [threading.Event() for _case in cases]
                def reversed_completion(item):
                    index, case = item
                    if index + 1 < len(cases) and not done[index + 1].wait(5):
                        raise AssertionError("four workers did not make progress")
                    completed.append(case[0])
                    done[index].set()
                    return case[0]
                return super().map(reversed_completion, enumerate(cases))

        with mock.patch.object(suite, "ThreadPoolExecutor", RecordingPool), redirect_stdout(io.StringIO()) as out:
            suite.mutants(only="G1 ", start_after="G1 executable mode change")
        self.assertEqual(selections, [["G1 flake lines", "G1 lock leaves", "G1 doc/test lines", "G1 running baseline"]])
        self.assertEqual(completed, list(reversed(selections[0])))
        self.assertEqual(out.getvalue().splitlines(), [
            *("must-fail mutant killed: " + label for label in selections[0]),
            "T125: 4 guard-removal mutants killed",
        ])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--negative-control"]:
        negative_control(sys.argv[2])
    else:
        unittest.main(verbosity=2)
