"""NIX-583: metadata boundaries, real HM evaluation, exact upstream flags."""

import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest
import plistlib
import platform
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("preflight", ROOT / "scripts/aeon-agentd-preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.enrollment = self.home / "Library/Application Support/aeon/agentd"
        self.enrollment.mkdir(parents=True, mode=0o700)
        self.workspace = self.home / "Code"
        self.workspace.mkdir()
        self.key = self.enrollment / "agent.key"
        self.accounts = self.enrollment / "accounts.json"
        for path in (self.key, self.accounts):
            path.write_text("synthetic fixture, not a credential")
            path.chmod(0o600)
        self.state = self.enrollment / "state"
        self.config = dict(home=str(self.home), agentKeyFile=str(self.key),
                           accountsFile=str(self.accounts), workspace=str(self.workspace), stateRoot=str(self.state))

    def test_check_is_read_only_and_never_reads_private_bytes(self):
        with patch.object(Path, "read_text", side_effect=AssertionError("private read")), \
             patch.object(Path, "read_bytes", side_effect=AssertionError("private read")):
            preflight.preflight(self.config)
        self.assertFalse(self.state.exists())

    def test_prepare_is_idempotent_and_preserves_logs_and_umask(self):
        prior = os.umask(0o027)
        try:
            preflight.preflight(self.config, prepare=True)
            log = self.state / "stdout.log"
            log.write_text("retained audit")
            preflight.preflight(self.config, prepare=True)
            self.assertEqual(log.read_text(), "retained audit")
            self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
            self.assertEqual(os.umask(0o027), 0o027)
        finally:
            os.umask(prior)

    def test_wrong_mode_including_generic_consumer_mode_rejected(self):
        for mode in (0o400, 0o644, 0o660):
            with self.subTest(mode=mode):
                self.key.chmod(mode)
                with self.assertRaises(ValueError):
                    preflight.preflight(self.config, prepare=True)
                self.assertFalse(self.state.exists())

    def test_symlink_key_and_hardlink_registry_rejected(self):
        alias = self.enrollment / "alias.key"
        alias.symlink_to(self.key)
        with self.assertRaises(ValueError):
            preflight.preflight(self.config | {"agentKeyFile": str(alias)})
        os.link(self.accounts, self.enrollment / "accounts-copy")
        with self.assertRaises(ValueError):
            preflight.preflight(self.config)

    def test_symlink_parent_and_workspace_rejected(self):
        alias = self.home / "alias"
        alias.symlink_to(self.enrollment, target_is_directory=True)
        with self.assertRaises(ValueError):
            preflight.preflight(self.config | {"agentKeyFile": str(alias / "agent.key")})
        with self.assertRaises(ValueError):
            preflight.preflight(self.config | {"workspace": str(alias)})

    def test_classic_path_and_shared_file_rejected(self):
        with self.assertRaises(ValueError):
            preflight.preflight(self.config | {"stateRoot": str(self.home / "Library/Caches/paimos/agentd")})
        with self.assertRaises(ValueError):
            preflight.preflight(self.config | {"accountsFile": str(self.key)})

    def test_workspace_cannot_contain_enrollment_or_state(self):
        with self.assertRaises(ValueError):
            preflight.preflight(self.config | {"workspace": str(self.home / "Library")})

    def test_wrong_owner_oversize_empty_and_missing_rejected(self):
        with patch.object(os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(ValueError):
                preflight.preflight(self.config)
        for value in ("", "x" * 4097):
            self.key.write_text(value)
            with self.assertRaises(ValueError):
                preflight.preflight(self.config)
        with self.assertRaises(OSError):
            preflight.preflight(self.config | {"agentKeyFile": str(self.enrollment / "missing")})

    def test_unsafe_state_and_log_rejected_without_repair(self):
        self.state.mkdir(parents=True, mode=0o755)
        with self.assertRaises(ValueError):
            preflight.preflight(self.config, prepare=True)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o755)
        self.state.chmod(0o700)
        log = self.state / "stdout.log"
        log.symlink_to(self.key)
        with self.assertRaises(ValueError):
            preflight.preflight(self.config, prepare=True)
        self.assertTrue(log.is_symlink())


class HomeManagerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).evidence'
        cls.evidence = json.loads(subprocess.check_output(
            ["nix", "eval", "--impure", "--json", "--expr", expr], cwd=ROOT))

    def test_opt_in_and_classic_unchanged(self):
        e = self.evidence
        self.assertFalse(e["moduleDefaultEnabled"])
        self.assertTrue(e["hostEnabled"])
        self.assertFalse(e["defaultEnabled"])
        self.assertFalse(e["defaultHasService"])
        self.assertEqual(e["assertions"], [])
        self.assertTrue(e["classicUnchanged"])
        self.assertTrue(e["classicActivationUnchanged"])

    def test_incomplete_enrollment_fails_closed(self):
        paths = "requires distinct private paths outside its workspace"
        vendor = "requires at least one pinned Nix store vendor executable"
        expected = dict(noEstimate="requires at least one approved positive allowance estimate",
                        emptyId="requires a stable opaque daemonId", sharedFiles=paths,
                        storeKey=paths, classicStateKey=paths, relativeWorkspace=paths,
                        workspaceContainsEnrollment=paths, mutableVendor=vendor, noAdapter=vendor)
        self.assertEqual(set(expected), set(self.evidence["invalid"]))
        for case, message in expected.items():
            with self.subTest(case=case):
                expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).invalidCandidates.{case}.drvPath'
                result = subprocess.run(["nix", "eval", "--impure", "--raw", "--expr", expr],
                                        cwd=ROOT, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Failed assertions", result.stderr)
                self.assertIn(message, result.stderr)

    def test_argv_matches_exact_reviewed_release(self):
        lock = json.loads((ROOT / "flake.lock").read_text())["nodes"]["aeon"]
        self.assertEqual(lock["locked"]["rev"], "3f8d613473ff3ff37db50ecff9e5522de73cc974")
        self.assertEqual(lock["locked"]["narHash"], "sha256-1n6+D1fWNjWE340XamloraspYs6SpbDEBeUWEFHxOa0=")
        source = subprocess.check_output(["nix", "eval", "--impure", "--raw", "--expr",
            f'(builtins.getFlake "{ROOT}").inputs.aeon.outPath'], cwd=ROOT, text=True).strip()
        main = (Path(source) / "cmd/aeon-agentd/main.go").read_text()
        supported = set(re.findall(r'f\.(?:String|Int64)Var\(&\w+, "([a-z-]+)"', main))
        service = self.evidence["service"]
        args = service["ProgramArguments"]
        self.assertTrue(args[0].endswith("/bin/aeon-agentd"))
        self.assertEqual(args[1], "serve")
        pairs = dict(zip(args[2::2], args[3::2]))
        self.assertEqual(len(pairs) * 2 + 2, len(args))
        self.assertTrue({f[2:] for f in pairs} <= supported)
        self.assertEqual(pairs["--url"], "https://aeon.barta.cm")
        self.assertEqual(pairs["--estimate-requests"], "1")
        for forbidden in ("--instance", "--report-url", "--codex-accounts", "--paimos-path"):
            self.assertNotIn(forbidden, pairs)
        self.assertEqual(service["Label"], "at.inspr.aeon-agentd")
        self.assertEqual(service["Umask"], 63)
        self.assertNotIn("INSPR_AGENT_BROWSER_GUARD", service["EnvironmentVariables"])
        self.assertRegex(service["EnvironmentVariables"]["PATH"], r"^/nix/store/[^/]+-nodejs-[^/]+/bin:/usr/bin:/bin:/usr/sbin:/sbin$")
        self.assertIn("--codex-path", pairs)
        self.assertIn("--cursor-path", pairs)
        self.assertIn("writeBoundary", self.evidence["preflight"]["before"])
        self.assertIn("setupLaunchAgents", self.evidence["state"]["before"])

    @unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                         "Darwin generation build requires Apple Silicon; CI covers evaluation")
    def test_built_generation_preserves_both_direct_plists(self):
        expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).candidate'
        candidate = Path(subprocess.check_output(
            ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr", expr], cwd=ROOT, text=True).strip())
        default = Path(subprocess.check_output(
            ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr",
             f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).disabledCandidate'],
            cwd=ROOT, text=True).strip())
        classic = 'LaunchAgents/at.inspr.paimos-agentd.plist'
        self.assertEqual((candidate / classic).read_bytes(), (default / classic).read_bytes())
        for label in ('aeon', 'paimos'):
            plist = plistlib.loads((candidate / f'LaunchAgents/at.inspr.{label}-agentd.plist').read_bytes())
            self.assertTrue(plist['ProgramArguments'][0].endswith(f'/bin/{label}-agentd'))
            self.assertEqual(plist['ProgramArguments'][1], 'serve')
        self.assertFalse((default / 'LaunchAgents/at.inspr.aeon-agentd.plist').exists())
        # Parse the generated helper, including its embedded JSON, without
        # running its real enrollment checks or writing into the Nix store.
        scripts = set(re.findall(r'/nix/store/[a-z0-9]+-aeon-agentd-preflight\.py', (candidate / 'activate').read_text()))
        self.assertEqual(len(scripts), 1)
        for path in scripts:
            ast.parse(Path(path).read_text(), filename=path)


if __name__ == "__main__":
    unittest.main()
