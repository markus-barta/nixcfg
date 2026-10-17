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


class Contract(unittest.TestCase):
    def test_nix_guard_options_and_assertions(self):
        nix = shutil.which("nix")
        self.assertTrue(nix, "Nix is required for the module contract")
        library = os.environ.get("NIXPKGS_LIB", "<nixpkgs/lib>")
        evaluated = subprocess.run(
            [nix, "eval", "--impure", "--json", "--file", str(ROOT / "tests/adguard-users-secret-eval.nix"),
             "--apply", f"f: f {{ lib = import {library}; }}"], capture_output=True, text=True,
        )
        self.assertEqual(evaluated.returncode, 0, "module evaluation failed (diagnostics withheld)")
        result = json.loads(evaluated.stdout)
        self.assertTrue(result["pending"]["valid"])
        self.assertEqual(result["pending"]["secrets"], {})
        service = result["pending"]["services"]["adguardhome"]["serviceConfig"]
        self.assertEqual(service["LoadCredential"], ["adguard-users:/run/agenix/hsb0-adguard-users"])
        self.assertEqual(service["ExecStartPre"], ["/inject-users"])
        self.assertEqual(result["provisioned"]["secrets"]["hsb0-adguard-users"], {
            "path": "/run/agenix/hsb0-adguard-users", "owner": "root", "group": "root", "mode": "0400",
        })
        for variant in ("disabled", "unconfigured"):
            self.assertEqual(result[variant]["services"], {})
            self.assertEqual(result[variant]["secrets"], {})
        self.assertFalse(result["mutable"]["valid"])
        self.assertFalse(result["inlineUsers"]["valid"])

    def test_no_bcrypt_literals_in_hosts_or_modules(self):
        findings = []
        for directory in ("hosts", "modules"):
            for path in (ROOT / directory).rglob("*"):
                if not path.is_file() or path.is_symlink() or path.suffix in {".age", ".env", ".gpg"}:
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
            self.assertFalse(re.search(r"\busers\s*=\s*\[[^\]]*\bpassword\s*=", text), f"{host}: inline user password")
            self.assertFalse(re.search(r"users(?:\.[\w-]+)*\.password\s*=", text), f"{host}: inline user password")
        module = (ROOT / "modules/adguard-users-secret.nix").read_text()
        self.assertIn("builtins.pathExists cfg.usersSecretFile", module)
        self.assertIn("age.secrets = lib.optionalAttrs hasSecret", module)
        self.assertIn('mode = "0400";', module)
        self.assertIn('owner = "root";', module)
        self.assertIn('group = "root";', module)
        self.assertIn('config.age.secrets.${secretName}.path', module)
        self.assertIn('LoadCredential = [ "adguard-users:${secretPath}" ]', module)
        self.assertIn('ExecStartPre = lib.mkAfter [ "${injectUsers}" ]', module)
        self.assertIn('"$STATE_DIRECTORY/AdGuardHome.yaml"', module)
        self.assertIn('"$CREDENTIALS_DIRECTORY/adguard-users"', module)
        self.assertIn("!cfg.mutableSettings", module)
        self.assertIn("!(cfg.settings ? users)", module)
        self.assertNotIn("ConditionPathExists", module)
        self.assertNotIn("builtins.readFile cfg.usersSecretFile", module)

    def test_guarded_recipients_and_ci(self):
        declarations = (ROOT / "secrets/secrets.nix").read_text()
        for host in ("hsb0", "hsb8"):
            self.assertRegex(
                declarations,
                rf'if builtins\.pathExists \./{host}-adguard-users\.age then\s*\{{\s*'
                rf'"{host}-adguard-users\.age"\.publicKeys = markus \+\+ {host};',
            )
        self.assertIn("python3 tests/T105-adguard-users-secret.py", (ROOT / ".github/workflows/check.yml").read_text())


class Runtime(unittest.TestCase):
    def setUp(self):
        if not YQ:
            self.fail("yq-go is required; runtime probes must not silently skip")
        self.scratch = tempfile.TemporaryDirectory(prefix="ops372-test-")
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "AdGuardHome.yaml"
        self.original = "schema_version: 29\ndns:\n  port: 53\nhttp:\n  address: 0.0.0.0:3000\nusers: []\n"
        self.config.write_text(self.original)
        self.config.chmod(0o600)
        # Synthetic grammar fixtures, constructed without storing a verifier
        # literal in production source. These authenticate no real account.
        self.fixture = {"name": "fixture-admin", "password": "$" + "2b" + "$12$" + "A" * 53}
        self.secret = self.directory / "users.json"

    def run_helper(self, payload, *, raw=False, yq=None):
        if self.secret.exists():
            self.secret.chmod(0o600)
        self.secret.write_text(payload if raw else json.dumps(payload))
        self.secret.chmod(0o400)
        return subprocess.run(
            [sys.executable, str(HELPER), str(self.config), str(self.secret), yq or YQ],
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
            self.assertEqual(settings["http"], {"address": "0.0.0.0:3000"})
            after = self.config.stat()
            self.assertEqual(stat.S_IMODE(after.st_mode), 0o600)
            self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))
        self.assertEqual(list(self.directory.glob(".adguard-users-*")), [])

    def test_malformed_or_empty_users_fail_without_output(self):
        invalid = [None, [], {}, [None], ["invalid"], [{}],
                   [dict(self.fixture, name=" ")], [dict(self.fixture, name=4)],
                   [dict(self.fixture, password="")], [dict(self.fixture, password=None)],
                   [dict(self.fixture, password="invalid")],
                   [dict(self.fixture, extra=True)], [self.fixture, self.fixture]]
        for payload in invalid:
            self.assert_closed(self.run_helper(payload))
        for payload in ("not json", "[", '[{"name":"a","name":"b","password":"invalid"}]'):
            self.assert_closed(self.run_helper(payload, raw=True))

    def test_missing_secret_fails(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), str(self.config), str(self.secret), YQ],
            capture_output=True, text=True,
        )
        self.assert_closed(result)

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
