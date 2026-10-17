#!/usr/bin/env python3
"""OPS-372 contracts and real YAML merge/failure probes; no live host access."""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "modules/adguard-users-secret.py"
YQ = shutil.which("yq")
FIXTURE_PROVISIONED = "--fixture-provisioned" in sys.argv
if FIXTURE_PROVISIONED:
    sys.argv.remove("--fixture-provisioned")


class Contract(unittest.TestCase):
    def test_nix_guard_options_and_assertions(self):
        nix = shutil.which("nix")
        self.assertTrue(nix, "Nix is required for the module contract")
        library = os.environ.get("NIXPKGS_LIB")
        self.assertTrue(library, "NIXPKGS_LIB must name the flake-pinned nixpkgs lib")
        evaluated = subprocess.run(
            [nix, "eval", "--impure", "--json", "--file", str(ROOT / "tests/adguard-users-secret-eval.nix"),
             "--apply", f"f: f {{ lib = import {library}; }}"], capture_output=True, text=True,
        )
        self.assertEqual(evaluated.returncode, 0, "module evaluation failed (diagnostics withheld)")
        result = json.loads(evaluated.stdout)
        self.assertFalse(result["pending"]["valid"], "pending evaluation MUST be RED")
        self.assertIn("ops372-deliberately-absent", result["pending"]["failures"][0])
        self.assertTrue(result["pending"]["warnings"])
        self.assertTrue(result["provisioned"]["valid"])
        self.assertTrue(result["provisionedPair"]["valid"])
        self.assertFalse(result["missingPeer"]["valid"])
        self.assertIn("absent-peer", result["missingPeer"]["failures"][0])
        self.assertEqual(result["pending"]["secrets"], {})
        service = result["pending"]["services"]["adguardhome"]["serviceConfig"]
        self.assertEqual(service["LoadCredential"], [])
        self.assertEqual(service["SetCredential"], ["adguard-users:"])
        self.assertEqual(result["pending"]["services"]["adguardhome"]["restartTriggers"], [])
        provisioned = result["provisioned"]["services"]["adguardhome"]
        self.assertEqual(provisioned["serviceConfig"]["LoadCredential"], ["adguard-users:/run/agenix/hsb0-adguard-users"])
        self.assertEqual(provisioned["restartTriggers"], [str(HELPER)])
        self.assertEqual(service["RuntimeDirectory"], "AdGuardHome")
        self.assertIn("admin-locked", result["provisioned"]["services"]["adguardhome-users-health"]["serviceConfig"]["ExecStart"])
        if FIXTURE_PROVISIONED:
            self.assertTrue(result["provisionedPair"]["valid"], "fixture provisioned state MUST be GREEN")
        self.assertEqual(service["ExecStartPre"], ["/inject-users"])
        self.assertEqual(result["provisioned"]["secrets"]["hsb0-adguard-users"], {
            "path": "/run/agenix/hsb0-adguard-users", "owner": "root", "group": "root", "mode": "0400",
        })
        for variant in ("disabled", "unconfigured"):
            self.assertEqual(result[variant]["services"], {})
            self.assertEqual(result[variant]["secrets"], {})
        self.assertFalse(result["mutable"]["valid"])
        self.assertFalse(result["inlineUsers"]["valid"])

    def test_cutover_readiness(self):
        if FIXTURE_PROVISIONED:
            # Existence uses harmless source paths, never a fake ciphertext.
            self.assertTrue(HELPER.is_file())
            self.assertTrue((ROOT / "tests/adguard-users-secret-eval.nix").is_file())
            return
        missing = [f"secrets/{name}" for name in (
            "adguard-admin-password.age", "hsb0-adguard-users.age", "hsb8-adguard-users.age"
        ) if not (ROOT / "secrets" / name).is_file()]
        self.assertFalse(missing, "Expected RED until provisioned: " + ", ".join(missing))

    def test_no_bcrypt_literals_in_tracked_files(self):
        findings = []
        paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        for item in paths:
            if not item:
                continue
            path = ROOT / os.fsdecode(item)
            if (not path.is_file() or path.is_symlink()
                    or path.name.endswith((".age", ".env", ".gpg"))):
                continue
            for line_number, line in enumerate(path.read_bytes().splitlines(), 1):
                if re.search(rb"\$2[aby]\$", line):
                    findings.append(f"{path.relative_to(ROOT)}:{line_number}")
        self.assertFalse(findings, "bcrypt literal at " + ", ".join(findings))

    def test_wiring_and_fail_closed_startup(self):
        for host in ("hsb0", "hsb8"):
            text = (ROOT / f"hosts/{host}/configuration.nix").read_text()
            self.assertTrue("../../modules/adguard-users-secret.nix" in text, f"{host}: missing secret module")
            self.assertTrue(f"usersSecretFile = ../../secrets/{host}-adguard-users.age;" in text, f"{host}: missing secret wiring")
            peer = "hsb8" if host == "hsb0" else "hsb0"
            self.assertIn(f'usersSecretPeers = [ (../../secrets + "/{peer}-adguard-users.age") ];', text)
            self.assertFalse(re.search(r"\busers\s*=\s*\[[^\]]*\bpassword\s*=", text), f"{host}: inline user password")
            self.assertFalse(re.search(r"users(?:\.[\w-]+)*\.password\s*=", text), f"{host}: inline user password")
        module = (ROOT / "modules/adguard-users-secret.nix").read_text()
        self.assertIn("builtins.pathExists cfg.usersSecretFile", module)
        self.assertIn("age.secrets = lib.optionalAttrs hasSecret", module)
        self.assertIn('mode = "0400";', module)
        self.assertIn('owner = "root";', module)
        self.assertIn('group = "root";', module)
        self.assertIn('config.age.secrets.${secretName}.path', module)
        self.assertIn('LoadCredential = lib.optional hasSecret', module)
        self.assertIn('ExecStartPre = lib.mkAfter [ "${injectUsers}" ]', module)
        self.assertIn('"$STATE_DIRECTORY/AdGuardHome.yaml"', module)
        self.assertIn('CREDENTIALS_DIRECTORY:-/nonexistent', module)
        self.assertIn("!cfg.mutableSettings", module)
        self.assertIn("!(cfg.settings ? users)", module)
        self.assertNotIn("ConditionPathExists", module)
        self.assertNotIn("builtins.readFile cfg.usersSecretFile", module)

    def test_plain_recipients_and_ci(self):
        declarations = (ROOT / "secrets/secrets.nix").read_text()
        for host in ("hsb0", "hsb8"):
            self.assertIn(f'"{host}-adguard-users.age".publicKeys = markus ++ {host};', declarations)
            self.assertNotIn(f'pathExists ./{host}-adguard-users.age', declarations)
        self.assertRegex(declarations, r'"adguard-admin-password.age"\.publicKeys = markus;')
        for directory in ("hosts", "modules"):
            for path in (ROOT / directory).rglob("*.nix"):
                self.assertNotIn("adguard-admin-password.age", path.read_text(), str(path))
        workflow = (ROOT / ".github/workflows/check.yml").read_text()
        self.assertIn("python3 tests/T105-adguard-users-secret.py", workflow)
        self.assertIn("NIXPKGS_LIB", workflow)
        self.assertIn("tests/adguard-users-full-host-eval.nix", workflow)


class Runtime(unittest.TestCase):
    def setUp(self):
        if not YQ:
            self.fail("yq-go is required; runtime probes must not silently skip")
        self.scratch = tempfile.TemporaryDirectory(prefix="ops372-test-")
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "AdGuardHome.yaml"
        self.original = "schema_version: 29\ndns:\n  port: 53\nhttp:\n  address: 0.0.0.0:3000\ndhcp:\n  enabled: true\nusers: []\n"
        self.config.write_text(self.original)
        self.config.chmod(0o600)
        # Synthetic grammar fixtures, constructed without storing a verifier
        # literal in production source. These authenticate no real account.
        self.fixture = {"name": "fixture-admin", "password": "$" + "2b" + "$12$" + "A" * 53}
        self.secret = self.directory / "users.json"
        self.marker = self.directory / "admin-locked"

    def run_helper(self, payload, *, raw=False, yq=None):
        if self.secret.exists():
            self.secret.chmod(0o600)
        self.secret.write_text(payload if raw else json.dumps(payload))
        self.secret.chmod(0o400)
        return subprocess.run(
            [sys.executable, str(HELPER), str(self.config), str(self.secret), yq or YQ, str(self.marker), "3000"],
            capture_output=True, text=True,
        )

    def assert_closed(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "AdGuard users injection failed; refusing to start (OPS-372).\n")
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(list(self.directory.glob(".adguard-users-*")), [])

    def test_merge_preserves_settings_permissions_and_ownership(self):
        before = self.config.stat()
        for prefix in ("2a", "2b", "2y"):
            fixture = dict(self.fixture, password="$" + prefix + "$12$" + "A" * 53)
            result = self.run_helper([fixture])
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
            parsed = subprocess.run([YQ, "-o=json", ".", str(self.config)], capture_output=True, check=True)
            settings = json.loads(parsed.stdout)
            self.assertTrue(settings["users"] == [fixture], "runtime users must match exactly")
            self.assertEqual(settings["dns"], {"port": 53})
            self.assertEqual(settings["dhcp"], {"enabled": True})
            self.assertEqual(settings["http"], {"address": "0.0.0.0:3000"})
            after = self.config.stat()
            self.assertEqual(stat.S_IMODE(after.st_mode), 0o600)
            self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))
        self.assertEqual(list(self.directory.glob(".adguard-users-*")), [])

    def assert_admin_locked(self, result):
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "AdGuard admin locked; DNS/DHCP remain enabled (OPS-372).\n")
        parsed = subprocess.run([YQ, "-o=json", ".", str(self.config)], capture_output=True, check=True)
        settings = json.loads(parsed.stdout)
        self.assertEqual(settings["dns"], {"port": 53})
        self.assertEqual(settings["dhcp"], {"enabled": True})
        self.assertEqual(settings["http"]["address"], "127.0.0.1:3000")
        self.assertEqual(len(settings["users"]), 1)
        self.assertTrue(re.fullmatch(r"\$2[aby]\$12\$[./A-Za-z0-9]{53}", settings["users"][0]["password"]))
        self.assertTrue(self.marker.is_file())
        self.assertEqual(stat.S_IMODE(self.marker.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_malformed_or_empty_users_lock_only_admin(self):
        invalid = [None, [], {}, [None], ["invalid"], [{}],
                   [dict(self.fixture, name=" ")], [dict(self.fixture, name=4)],
                   [dict(self.fixture, password="")], [dict(self.fixture, password=None)],
                   [dict(self.fixture, password="invalid")],
                   [dict(self.fixture, extra=True)], [self.fixture, self.fixture]]
        for payload in invalid:
            self.assert_admin_locked(self.run_helper(payload))
        for payload in ("not json", "[", '[{"name":"a","name":"b","password":"invalid"}]'):
            self.assert_admin_locked(self.run_helper(payload, raw=True))

    def test_locked_mode_random_input_is_reliable(self):
        for iteration in range(64):
            with self.subTest(iteration=iteration):
                self.config.write_text(self.original)
                self.assert_admin_locked(self.run_helper([]))

    def test_missing_secret_locks_only_admin(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), str(self.config), str(self.secret), YQ, str(self.marker), "3000"],
            capture_output=True, text=True,
        )
        self.assert_admin_locked(result)

    def test_recovery_clears_marker_and_restores_template_http(self):
        self.assert_admin_locked(self.run_helper([]))
        # Upstream recopies the declarative template before every restart.
        self.config.write_text(self.original)
        result = self.run_helper([self.fixture])
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertFalse(self.marker.exists())
        parsed = subprocess.run([YQ, "-o=json", ".", str(self.config)], capture_output=True, check=True)
        self.assertEqual(json.loads(parsed.stdout)["http"]["address"], "0.0.0.0:3000")

    def test_parser_and_write_failures_do_not_publish_partial_config(self):
        self.assert_closed(self.run_helper([self.fixture], yq="/nonexistent/yq"))
        fake_yq = self.directory / "yq-failure"
        fake_yq.write_text('#!/bin/sh\ncase "$*" in\n  *-o=json*) printf "{}";;\n  *) printf "partial"; echo "sensitive-parser-diagnostic" >&2; exit 1;;\nesac\n')
        fake_yq.chmod(0o700)
        self.assert_closed(self.run_helper([self.fixture], yq=str(fake_yq)))

    def test_invalid_template_fails_and_hides_parser_diagnostics(self):
        self.original = "{ broken YAML: ["
        self.config.write_text(self.original)
        self.assert_closed(self.run_helper([self.fixture]))

    def test_runtime_symlink_is_rejected(self):
        actual = self.directory / "actual.yaml"
        self.config.rename(actual)
        self.config.symlink_to(actual)
        self.assert_closed(self.run_helper([self.fixture]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
