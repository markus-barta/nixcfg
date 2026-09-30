"""NIX-583: metadata boundaries, real HM evaluation, exact upstream flags."""

import ast
import importlib.util
import json
import sys
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


class PairedPreflightTests(unittest.TestCase):
    """NIX-589: metadata-only gate before switching to the paired runtime."""

    HINT = "run `aeon-agentd setup …`, approve the computer in Aeon, then switch again"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir(mode=0o750)
        support = self.home / "Library/Application Support"
        support.mkdir(parents=True, mode=0o700)
        (self.home / "Library").chmod(0o700)
        self.root = support / "aeon/paired"
        self.enrollment = support / "aeon/agentd"
        self.workspace = self.home / "Code"
        self.workspace.mkdir()
        self.logs = self.home / "Library/Logs/aeon-agentd"
        self.config = dict(mode="paired", home=str(self.home), workspace=str(self.workspace),
                           pairedRoot=str(self.root), logRoot=str(self.logs), pairHint=self.HINT,
                           managedPaths=[str(self.enrollment), str(self.enrollment / "state")])

    def approve(self):
        self.root.parent.mkdir(mode=0o700, exist_ok=True)
        self.root.mkdir(mode=0o700)
        for name in preflight.PAIRED_FILES:
            path = self.root / name
            path.write_text("synthetic fixture, not a credential")
            path.chmod(0o600)

    def run_gate(self, config=None, prepare=False):
        preflight.paired_preflight(config or self.config, prepare=prepare)

    def refused(self, config=None, prepare=False):
        with self.assertRaises(preflight.PreflightError) as caught:
            self.run_gate(config, prepare)
        return str(caught.exception)

    def test_upstream_files_and_bounds(self):
        # Aeon 6b5e5e7c agentsetup: Engine.load, ReadRuntimeConfig, ReadRuntime.
        self.assertEqual(preflight.PAIRED_FILES,
                         {"pairing.json": 1 << 20, "runtime.json": 128 << 10, "runtime.key": 4096})

    def test_missing_root_refused_with_the_pairing_command(self):
        self.assertIn(self.HINT, self.refused())
        self.assertIn("no approved pairing yet", self.refused())

    def test_each_missing_file_refused_with_the_pairing_command(self):
        for name in preflight.PAIRED_FILES:
            with self.subTest(missing=name):
                self.approve()
                (self.root / name).unlink()
                message = self.refused()
                self.assertIn(name, message)
                self.assertIn(self.HINT, message)
                for path in self.root.iterdir():
                    path.unlink()
                self.root.rmdir()

    def test_each_file_refused_when_empty_or_over_its_upstream_bound(self):
        self.approve()
        for name, maximum in preflight.PAIRED_FILES.items():
            path = self.root / name
            for size in (0, maximum + 1):
                with self.subTest(file=name, size=size):
                    os.truncate(path, size)  # metadata only; contents never read
                    self.refused()
            os.truncate(path, maximum)
        self.run_gate()  # exactly at every bound is accepted

    def test_approved_root_passes_read_only_and_prepare_creates_private_logs(self):
        self.approve()
        with patch.object(Path, "read_text", side_effect=AssertionError("private read")), \
             patch.object(Path, "read_bytes", side_effect=AssertionError("private read")), \
             patch("builtins.open", side_effect=AssertionError("private read")):
            self.run_gate()
        self.assertFalse(self.logs.exists())
        self.run_gate(prepare=True)
        self.assertEqual(stat.S_IMODE(self.logs.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.logs.parent.stat().st_mode), 0o700)
        for name in ("stdout.log", "stderr.log"):
            self.assertEqual(stat.S_IMODE((self.logs / name).stat().st_mode), 0o600)
        self.run_gate(prepare=True)  # idempotent

    def test_prepare_ignores_an_inherited_restrictive_umask_and_restores_it(self):
        self.approve()
        prior = os.umask(0o277)
        try:
            self.run_gate(prepare=True)
            self.assertEqual(os.umask(0o277), 0o277)  # restored after preparation
        finally:
            os.umask(prior)
        for directory in (self.home / "Library/Logs", self.logs):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        for name in ("stdout.log", "stderr.log"):
            self.assertEqual(stat.S_IMODE((self.logs / name).stat().st_mode), 0o600)

    def test_too_open_root_or_files_refused(self):
        self.approve()
        self.root.chmod(0o750)
        self.refused()
        self.root.chmod(0o700)
        (self.root / "runtime.key").chmod(0o644)
        self.refused()

    def test_writable_pairing_ancestor_refused(self):
        self.approve()
        self.root.parent.chmod(0o777)
        self.assertIn("ancestor", self.refused())

    def test_writable_log_parent_refused(self):
        self.approve()
        (self.home / "Library/Logs").mkdir(mode=0o700)
        (self.home / "Library/Logs").chmod(0o777)
        self.assertIn("ancestor", self.refused())
        self.assertIn("ancestor", self.refused(prepare=True))
        self.assertFalse(self.logs.exists())

    def test_writable_ancestor_above_home_refused(self):
        self.approve()
        self.base.chmod(0o775)
        self.assertIn("ancestor", self.refused())

    def test_symlinked_log_parent_or_credential_refused(self):
        self.approve()
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir(mode=0o700)
        (self.home / "Library/Logs").symlink_to(elsewhere, target_is_directory=True)
        self.refused(prepare=True)
        self.assertFalse((elsewhere / "aeon-agentd").exists())
        (self.home / "Library/Logs").unlink()
        key = self.root / "runtime.key"
        key.unlink()
        key.symlink_to(self.root / "runtime.json")
        self.refused()

    def test_overlap_with_workspace_explicit_key_state_classic_or_store_refused(self):
        self.approve()
        for name, root in {"workspace": self.workspace / "paired",
                           "explicit-key state": self.enrollment / "paired",
                           "explicit-key root": self.enrollment,
                           "classic": self.home / "Library/Application Support/paimos/paired",
                           "store": Path("/nix/store/example/paired"),
                           "outside home": Path("/tmp/paired")}.items():
            with self.subTest(case=name):
                self.refused(self.config | {"pairedRoot": str(root)})

    def test_main_dispatches_by_mode(self):
        with patch.object(sys, "argv", ["preflight", "check"]), \
             patch.object(preflight, "paired_preflight") as paired, \
             patch.object(preflight, "preflight") as managed:
            preflight.main({"mode": "paired"})
            preflight.main({})
        paired.assert_called_once()
        managed.assert_called_once()


class HomeManagerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).evidence'
        cls.evidence = json.loads(subprocess.check_output(
            ["nix", "eval", "--impure", "--json", "--expr", expr], cwd=ROOT))

    def test_opt_in_without_classic_agentd(self):
        e = self.evidence
        self.assertFalse(e["moduleDefaultEnabled"])
        self.assertTrue(e["hostEnabled"])
        self.assertFalse(e["defaultEnabled"])
        self.assertFalse(e["defaultHasService"])
        self.assertEqual(e["assertions"], [])
        self.assertFalse(e["hasClassicAgent"])

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

    def test_option_docs_use_the_version_aware_pairing_command(self):
        text = self.evidence["pairedEnableDescription"]
        # Release 12 (the pinned aeon input) has `pair` (AEON-333); workspace and
        # pairing root stay explicit because `pair` would default to the cwd.
        self.assertIn("`aeon-agentd pair --workspace '<workspace>' --state-root '<paired.stateRoot>'", text)
        self.assertNotIn("aeon-agentd setup", text)

    def test_paired_mode_is_opt_in_and_default_root_matches_aeon_pair(self):
        e = self.evidence
        self.assertFalse(e["pairedDefaultEnabled"])
        # mbp2607 is paired but stays managed until the Aeon socket-path fix (NIX-589).
        self.assertFalse(e["hostPairedEnabled"])
        self.assertTrue(e["pairedStateRootDefault"].endswith("/Library/Application Support/aeon/paired"))
        self.assertEqual(e["pairedAssertions"], [])

    def test_paired_service_is_the_same_label_with_setup_root_only(self):
        e = self.evidence
        service = e["pairedService"]
        self.assertEqual(service["Label"], "at.inspr.aeon-agentd")
        self.assertEqual(service["Label"], e["managedService"]["Label"])
        args = service["ProgramArguments"]
        self.assertTrue(args[0].endswith("/bin/aeon-agentd"))
        self.assertEqual(args[1:], ["serve", "--setup-root", e["pairedStateRootDefault"]])
        self.assertEqual(service["Umask"], 63)
        self.assertEqual({k: v for k, v in service["KeepAlive"].items() if v is not None},
                         {"SuccessfulExit": False})
        env = service["EnvironmentVariables"]
        self.assertEqual(env["PATH"], e["claudeRuntime"]["node"][:-len("/node")] + ":/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertTrue(service["StandardOutPath"].endswith("/Library/Logs/aeon-agentd/stdout.log"))
        self.assertIn("writeBoundary", e["pairedPreflight"]["before"])
        self.assertIn("aeon-agentd-paired-preflight.py", e["pairedPreflight"]["data"])
        self.assertIn("setupLaunchAgents", e["pairedState"]["before"])

    def test_managed_mode_unchanged_when_paired_is_off(self):
        # The host keeps paired mode off: its service is exactly the managed one.
        # Byte-level evidence for the PR: the built plist is identical to the
        # installed pre-NIX-589 generation; here the evaluated service must be
        # exactly the explicit-key one.
        self.assertEqual(self.evidence["managedService"], self.evidence["service"])
        self.assertIn("--agent-key-file", self.evidence["managedService"]["ProgramArguments"])
        self.assertNotIn("--setup-root", self.evidence["managedService"]["ProgramArguments"])

    def test_invalid_paired_roots_fail_evaluation(self):
        message = "requires a private pairing root outside its workspace"
        expected = {"pairedInWorkspace", "pairedInStore", "pairedInExplicitKeyState",
                    "pairedIsExplicitKeyState", "pairedInClassic", "pairedRelative"}
        self.assertEqual(expected, set(self.evidence["invalidPaired"]))
        for case in sorted(expected):
            with self.subTest(case=case):
                expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).invalidPairedCandidates.{case}.drvPath'
                result = subprocess.run(["nix", "eval", "--impure", "--raw", "--expr", expr],
                                        cwd=ROOT, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_browser_refusal_is_scoped_to_codex_not_the_paired_daemon(self):
        # NIX-578: Cursor/Claude keep the native headless route. The paired
        # daemon env carries no refusal; setup pins the physical `codex` on the
        # pairing shell's PATH, which is the guard's env-only launcher.
        e = self.evidence
        env = e["pairedService"]["EnvironmentVariables"]
        for name in list(e["guardEnvironment"]) + ["INSPR_AGENT_BROWSER_GUARD"]:
            self.assertNotIn(name, env)
        self.assertIn("codex", e["guardPrograms"]["envOnly"])
        for harness in ("cursor-agent", "claude"):
            self.assertIn(harness, e["guardPrograms"]["native"])
            self.assertNotIn(harness, e["guardPrograms"]["envOnly"])
            self.assertNotIn(harness, e["guardPrograms"]["shadowed"])

    def test_agentd_on_path_and_claude_runtime_pinned_and_gc_rooted(self):
        e = self.evidence
        self.assertIn(e["agentdName"], e["homePackages"])
        rt = e["claudeRuntime"]
        # Fixed-output derivations: nixpkgs/HM updates never move these paths.
        self.assertTrue(rt["nodeFixedOutput"])
        self.assertTrue(rt["sdkFixedOutput"])
        self.assertEqual(e["runtimeFiles"]["node"], rt["node"])
        self.assertEqual(e["runtimeFiles"]["sdk"], rt["sdk"])
        self.assertIn("-aeon-agentd-node-", rt["node"])
        self.assertIn("-aeon-agentd-claude-agent-sdk-", rt["sdk"])

    @unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                         "Darwin generation build requires Apple Silicon; CI covers evaluation")
    def test_built_paired_generation_hint_plist_and_launchers(self):
        expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).pairedActivation'
        gen = Path(subprocess.check_output(
            ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr", expr], cwd=ROOT, text=True).strip())
        e = self.evidence
        home = str(Path(e["pairedStateRootDefault"]).parents[3])
        script = Path(e["pairedPreflightScript"]).read_text()
        config = json.loads(json.loads(re.search(r"json\.loads\((\".*\")\)", script).group(1)))
        # The pinned release (d6375207, release 12) has `pair` (AEON-333).
        self.assertEqual(config["pairHint"], "run `aeon-agentd pair --workspace " + e["workspace"]
                         + " --state-root '" + e["pairedStateRootDefault"] + "' --url https://aeon.barta.cm"
                         + " --harness claude --node-path " + home + "/.local/share/aeon-agentd/bin/node"
                         + " --claude-sdk-path " + home + "/.local/share/aeon-agentd/lib/node_modules/"
                         + "@anthropic-ai/claude-agent-sdk/sdk.mjs`, approve the computer in Aeon, then switch again")
        plist = plistlib.loads((gen / "LaunchAgents/at.inspr.aeon-agentd.plist").read_bytes())
        self.assertEqual(plist["ProgramArguments"][1:], ["serve", "--setup-root", e["pairedStateRootDefault"]])
        self.assertNotIn("INSPR_AGENT_BROWSER_GUARD", plist["EnvironmentVariables"])
        shadow = re.search(r"(/nix/store/[a-z0-9]+-inspr-agent-guard-shadow-bin)/bin",
                           (gen / "home-files/.config/zsh/.zshrc").read_text()).group(1)
        codex = Path(os.path.realpath(f"{shadow}/bin/codex")).read_text()
        self.assertIn("INSPR_AGENT_BROWSER_GUARD", codex)
        for harness in ("cursor-agent", "claude"):
            self.assertNotIn("INSPR_AGENT_BROWSER_GUARD", Path(os.path.realpath(f"{shadow}/bin/{harness}")).read_text())

    def test_darwin_agentd_is_the_signed_release_binary(self):
        # NIX-588 / AEON-285: macOS runs the Developer ID signed release asset
        # from the same tag as the aeon input, never the ad-hoc source build.
        expr = (f'let f = builtins.getFlake "{ROOT}"; p = f.packages.aarch64-darwin.aeon-agentd; '
                'in builtins.toJSON { inherit (p) version; team = p.passthru.teamID or ""; '
                'url = p.src.url or (builtins.head p.src.urls); fixup = p.dontFixup or false; }')
        info = json.loads(subprocess.check_output(["nix", "eval", "--impure", "--raw", "--expr", expr], cwd=ROOT, text=True))
        tag = json.loads((ROOT / "flake.lock").read_text())["nodes"]["aeon"]["original"]["ref"]
        self.assertEqual("v" + info["version"], tag)
        self.assertEqual(info["team"], "P66J39QV6V")
        self.assertTrue(info["fixup"])
        self.assertEqual(info["url"], f"https://github.com/inspr-at/paimos/releases/download/{tag}/paimos-agentd-darwin-arm64")

    def test_signed_agentd_check_mirrors_the_daemon_gate(self):
        # The build must refuse exactly what the daemon's Touch ID gate refuses.
        expr = (f'(builtins.getFlake "{ROOT}").packages.aarch64-darwin.aeon-agentd.installCheckPhase')
        check = subprocess.check_output(["nix", "eval", "--impure", "--raw", "--expr", expr], cwd=ROOT, text=True)
        for needle in ("anchor apple generic",
                       "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
                       'certificate leaf[subject.OU] = "P66J39QV6V"',
                       "TeamIdentifier=P66J39QV6V", "flags=.*runtime",
                       "check-entitlements.py"):
            self.assertIn(needle, check)

    def test_entitlement_check_accepts_only_absent_or_false(self):
        script = ROOT / "pkgs/aeon-agentd-signed/check-entitlements.py"
        def plist(body):
            return ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                    f'{body}</dict></plist>')
        keys = ("com.apple.security.get-task-allow",
                "com.apple.security.cs.disable-library-validation",
                "com.apple.security.cs.allow-dyld-environment-variables")
        accepted = {"empty": "", "no entitlements at all": None,
                    "unrelated key": "<key>com.apple.security.network.client</key><true/>"}
        for key in keys:
            accepted[f"{key} false"] = f"<key>{key}</key>\n\t<false/>"
        rejected = {}
        for key in keys:
            for name, value in {"true": "<true/>", "integer 1": "<integer>1</integer>",
                                "string YES": "<string>YES</string>", "array": "<array/>",
                                "missing value": ""}.items():
                rejected[f"{key} {name}"] = f"<key>{key}</key>{value}"
            rejected[f"{key} duplicate"] = f"<key>{key}</key><false/><key>{key}</key><true/>"
            encoded = key[:-1] + "&#%d;" % ord(key[-1])
            rejected[f"{key} entity-encoded"] = f"<key>{encoded}</key><true/>"
        for name, body in accepted.items():
            with self.subTest(accepted=name):
                data = "" if body is None else plist(body)
                self.assertEqual(subprocess.run([sys.executable, script], input=data, text=True, capture_output=True).returncode, 0)
        raw_rejected = {"malformed": "<plist><dict><key>x</key>", "array root": '<plist version="1.0"><array/></plist>',
                        "not a plist": "hello"}
        for name, data in raw_rejected.items():
            with self.subTest(rejected=name):
                self.assertNotEqual(subprocess.run([sys.executable, script], input=data, text=True, capture_output=True).returncode, 0)
        for name, body in rejected.items():
            with self.subTest(rejected=name):
                self.assertNotEqual(subprocess.run([sys.executable, script], input=plist(body), text=True, capture_output=True).returncode, 0)

    def test_argv_matches_exact_reviewed_release(self):
        lock = json.loads((ROOT / "flake.lock").read_text())["nodes"]["aeon"]
        self.assertEqual(lock["locked"]["rev"], "d6375207f66578bfd0842c3653ea629b98059981")
        self.assertEqual(lock["locked"]["narHash"], "sha256-MsGYvdcpkwo02c3ajOq0byKT6wGo4okRRp7IosNnxZc=")
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
    def test_built_generation_preserves_aeon_plist_without_classic(self):
        expr = f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).candidate'
        candidate = Path(subprocess.check_output(
            ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr", expr], cwd=ROOT, text=True).strip())
        default = Path(subprocess.check_output(
            ["nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr",
             f'(import {ROOT}/tests/aeon-agentd-eval.nix {{ root = {ROOT}; }}).disabledCandidate'],
            cwd=ROOT, text=True).strip())
        self.assertFalse((candidate / 'LaunchAgents/at.inspr.paimos-agentd.plist').exists())
        self.assertFalse((default / 'LaunchAgents/at.inspr.paimos-agentd.plist').exists())
        plist = plistlib.loads((candidate / 'LaunchAgents/at.inspr.aeon-agentd.plist').read_bytes())
        self.assertTrue(plist['ProgramArguments'][0].endswith('/bin/aeon-agentd'))
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
