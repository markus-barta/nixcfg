#!/usr/bin/env python3
"""Run the GC unit suite in reproducible orders and detect process-state leaks."""

import argparse
import os
from pathlib import Path
import random
import signal
import sys
import unittest


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def process_state():
    # Read the umask without retaining a changed value. No environment values
    # enter diagnostics, even on a failure.
    mask = os.umask(0)
    os.umask(mask)
    return (dict(os.environ), os.getcwd(), mask,
            {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGALRM, signal.SIGINT, signal.SIGHUP)})


class StateCheckedResult(unittest.TextTestResult):
    def startTest(self, test):
        self.before = process_state()
        super().startTest(test)

    def stopTest(self, test):
        if process_state() != self.before:
            try:
                raise AssertionError("test leaked environment, cwd, umask or signal handlers")
            except AssertionError:
                self.addFailure(test, sys.exc_info())
        super().stopTest(test)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--order", choices=("random", "reverse"), required=True)
    parser.add_argument("--seed", type=int, default=32706, help="PRNG seed; reverse order uses no PRNG")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.discover(str(Path(__file__).resolve().parent), pattern="test_docker_image_gc.py")
    tests = list(flatten(suite))
    if args.order == "random":
        random.Random(args.seed).shuffle(tests)
    else:
        tests.reverse()
    print(f"order={args.order} seed={args.seed} tests={len(tests)}", flush=True)
    result = unittest.TextTestRunner(resultclass=StateCheckedResult).run(unittest.TestSuite(tests))
    return int(not result.wasSuccessful())


if __name__ == "__main__":
    sys.exit(main())
