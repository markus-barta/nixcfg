"""Offline regression checks for the private pin test's failure policy."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('pin_test', ROOT / 'scripts/test-joe-results-contracts-pin.py')
PIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PIN)


class RecreatePinTests(unittest.TestCase):
    def run_unavailable(self, ci):
        real_run = subprocess.run

        def run(command, **kwargs):
            if command[0] == 'nix':
                # Deliberately private-looking stderr must never reach output.
                return subprocess.CompletedProcess(command, 1, '', 'untrusted-fetch-detail')
            return real_run(command, **kwargs)

        output = io.StringIO()
        with patch.dict(os.environ, {'GITHUB_ACTIONS': str(ci).lower()}), \
                patch('sys.argv', ['pin-test']), patch.object(PIN.subprocess, 'run', side_effect=run), \
                contextlib.redirect_stdout(output):
            if ci:
                with self.assertRaisesRegex(SystemExit, 'FAIL recreate-from-pin'):
                    PIN.main()
            else:
                PIN.main()
                self.assertIn('SKIP recreate-from-pin', output.getvalue())
        self.assertNotIn('untrusted-fetch-detail', output.getvalue())

    def test_ci_fetch_failure_is_fatal(self):
        self.run_unavailable(True)

    def test_local_fetch_failure_is_explicit_skip(self):
        self.run_unavailable(False)

    def test_ci_cannot_bypass_fetch_with_local_flags(self):
        for args in [['--offline'], ['--source', '/unused']]:
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), patch('sys.argv', ['pin-test', *args]):
                with self.assertRaisesRegex(SystemExit, 'CI requires'):
                    PIN.main()

    def test_explicit_offline_reports_skip(self):
        output = io.StringIO()
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), patch('sys.argv', ['pin-test', '--offline']), contextlib.redirect_stdout(output):
            PIN.main()
        self.assertIn('SKIP recreate-from-pin: explicitly offline', output.getvalue())

    def test_recreated_closure_is_verified_including_extra_files(self):
        lock = json.loads((PIN.MODULE / 'contracts.lock.json').read_text())
        with tempfile.TemporaryDirectory(prefix='joed20-pin-policy-') as directory:
            source = Path(directory)
            shutil.copytree(PIN.MODULE / 'contracts', source / 'contracts')
            with contextlib.redirect_stdout(io.StringIO()):
                PIN.recreate(source, lock)
            (source / 'contracts/unexpected.json').write_text('{}')
            # Only the closure check can reject an unexpected source file: the
            # per-file comparison alone would miss it.
            with self.assertRaises(subprocess.CalledProcessError):
                PIN.recreate(source, lock)


if __name__ == '__main__':
    unittest.main()
