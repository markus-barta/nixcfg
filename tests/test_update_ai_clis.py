#!/usr/bin/env python3
"""Offline publication, failure, concurrency and rollback tests for NIX-524."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/update-ai-clis.py"
FAKE_NPM = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
fixture = json.loads(Path(os.environ["FIXTURE"]).read_text())
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps({"args": args, "grok_home": os.environ.get("GROK_HOME")}) + "\n")
if args[0] == "view":
    if fixture.get("offline"):
        sys.exit(7)
    name, requested = args[1].rsplit("@", 1)
    version = fixture["versions"][name] if requested == "latest" else requested
    data = {"version": version}
    if name in fixture.get("unsupported", []):
        data["os"] = ["unsupported-fixture-platform"]
    print(json.dumps(data))
elif args[0] == "install":
    prefix = Path(args[args.index("--prefix") + 1])
    Path(os.environ["READY"]).touch()
    time.sleep(fixture.get("delay", 0))
    name, version = args[-1].rsplit("@", 1)
    if name in fixture.get("fail", []):
        sys.exit(42)
    package = prefix / "lib/node_modules" / name
    package.mkdir(parents=True)
    metadata = {"name": name, "version": version}
    if fixture.get("wrong_metadata"):
        metadata["version"] = "0.0.0"
    (package / "package.json").write_text(json.dumps(metadata))
    target = package / "cli"
    body = "exit 9" if fixture.get("broken") else "echo " + version
    target.write_text("#!/bin/sh\n" + body + "\n")
    target.chmod(0o755)
    (prefix / "bin").mkdir()
    (prefix / "bin" / fixture["bins"][name]).symlink_to(target)
    # Model Grok's extra install-time side effect. It must stay in staging.
    home = Path(os.environ["GROK_HOME"])
    home.mkdir()
    (home / "postinstall-ran").touch()
else:
    sys.exit(99)
'''


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-ai-clis-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / "npm global"
        (self.prefix / "bin").mkdir(parents=True)
        self.fixture = {"versions": {"@test/one": "2.0.0", "@test/two": "2.0.0"},
                        "bins": {"@test/one": "one", "@test/two": "two"}}
        self.packages = self.root / "packages.json"
        self.packages.write_text(json.dumps([
            {"name": name, "version": "latest", "bin": binary}
            for name, binary in self.fixture["bins"].items()
        ]))
        self.approvals = self.root / "allow.json"
        self.approvals.write_text(json.dumps({"allowScripts": ["@test/one"]}))
        self.npm = self.root / "npm"
        self.npm.write_text(FAKE_NPM)
        self.npm.chmod(0o755)
        self.log = self.root / "calls"
        self.ready = self.root / "ready"
        self.data = self.root / "fixture.json"
        self.env = dict(os.environ, FIXTURE=str(self.data), CALLS=str(self.log),
                        READY=str(self.ready), GROK_HOME=str(self.root / "live-grok"))
        self.command = [sys.executable, str(SCRIPT), "--prefix", str(self.prefix),
                        "--packages", str(self.packages), "--allow-scripts",
                        str(self.approvals), "--npm", str(self.npm)]
        self.old_targets = {}
        for name, binary in self.fixture["bins"].items():
            package = self.prefix / "lib/node_modules" / name
            package.mkdir(parents=True)
            (package / "package.json").write_text(json.dumps({"name": name, "version": "1.0.0"}))
            executable = package / "cli"
            executable.write_text("#!/bin/sh\necho 1.0.0\n")
            executable.chmod(0o755)
            link = self.prefix / "bin" / binary
            link.symlink_to(executable)
            self.old_targets[binary] = str(executable)

    def run_update(self, *args):
        self.data.write_text(json.dumps(self.fixture))
        return subprocess.run(self.command + list(args), env=self.env,
                              capture_output=True, text=True, timeout=20)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def installs(self):
        return [call for call in self.calls() if call["args"][0] == "install"]

    def links(self):
        return {name: os.readlink(self.prefix / "bin" / name) for name in self.old_targets}

    def assert_old(self):
        self.assertEqual(self.links(), self.old_targets)
        for target in self.old_targets.values():
            self.assertIn("1.0.0", Path(target).read_text())

    def test_current_versions_skip_all_installs_and_link_changes(self):
        self.fixture["versions"] = dict.fromkeys(self.fixture["bins"], "1.0.0")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no installation or launch-link changes", result.stdout)
        self.assertFalse(self.installs())
        self.assert_old()

    def test_stages_exact_versions_and_preserves_legacy_and_unmanaged_bins(self):
        unmanaged = self.prefix / "bin" / "unmanaged"
        unmanaged.write_text("keep")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in self.installs():
            args = call["args"]
            stage = Path(args[args.index("--prefix") + 1])
            self.assertTrue(stage.is_relative_to(self.prefix / ".ai-cli-updates"))
            self.assertEqual(call["grok_home"], str(stage / "grok-home"))
            self.assertIn("--allow-scripts=@test/one", args)
            self.assertTrue(args[-1].endswith("@2.0.0"))
        self.assertFalse((self.root / "live-grok").exists())
        self.assertEqual(unmanaged.read_text(), "keep")
        for name, target in self.old_targets.items():
            self.assertIn("1.0.0", Path(target).read_text())
            self.assertIn("2.0.0", (self.prefix / "bin" / name).read_text())
        # A second run must discover versions through the published links,
        # not through stale legacy package.json files.
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.installs()), 2)

    def test_only_changed_package_is_installed(self):
        self.fixture["versions"]["@test/one"] = "1.0.0"
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.installs()), 1)
        self.assertEqual(self.links()["one"], self.old_targets["one"])

    def test_failed_second_install_publishes_neither_package(self):
        self.fixture["fail"] = ["@test/two"]
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_failed_validation_preserves_old_links(self):
        self.fixture["broken"] = True
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_wrong_package_metadata_is_not_published(self):
        self.fixture["wrong_metadata"] = True
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_broken_current_version_is_repaired_in_staging(self):
        self.fixture["versions"] = dict.fromkeys(self.fixture["bins"], "1.0.0")
        Path(self.old_targets["one"]).write_text("#!/bin/sh\nexit 1\n")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.installs()), 1)
        self.assertNotEqual(self.links()["one"], self.old_targets["one"])

    def test_offline_failure_keeps_old_installation(self):
        self.fixture["offline"] = True
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.installs())
        self.assert_old()

    def test_pinned_package_never_resolves_latest(self):
        packages = json.loads(self.packages.read_text())
        packages[0]["version"] = "1.0.0"
        self.packages.write_text(json.dumps(packages))
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.links()["one"], self.old_targets["one"])
        self.assertIn("@test/one@1.0.0", self.calls()[0]["args"])

    def test_unsupported_package_does_not_block_other_packages(self):
        self.fixture["unsupported"] = ["@test/one"]
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.links()["one"], self.old_targets["one"])
        self.assertEqual(len(self.installs()), 1)

    def test_check_does_not_create_state_or_install(self):
        result = self.run_update("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.prefix / ".ai-cli-updates").exists())
        self.assertFalse(self.installs())
        self.assert_old()

    def start_slow_update(self):
        self.fixture["delay"] = 0.5
        self.data.write_text(json.dumps(self.fixture))
        process = subprocess.Popen(self.command, env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(lambda: process.poll() is None and os.killpg(process.pid, signal.SIGKILL))
        deadline = time.monotonic() + 5
        while not self.ready.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(self.ready.exists())
        return process

    def test_concurrent_invocation_refuses_before_npm(self):
        process = self.start_slow_update()
        before = len(self.calls())
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owns the lock", result.stderr)
        self.assertEqual(len(self.calls()), before)
        process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0)

    def test_launches_never_disappear_during_update(self):
        process = self.start_slow_update()
        observed = set()
        samples = 0
        while process.poll() is None:
            for name in self.old_targets:
                result = subprocess.run([str(self.prefix / "bin" / name), "--version"],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(result.stdout.strip(), ("1.0.0", "2.0.0"))
                observed.add(result.stdout.strip())
                samples += 1
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertGreater(samples, 10)
        self.assertIn("1.0.0", observed)
        for name in self.old_targets:
            self.assertIn("2.0.0", (self.prefix / "bin" / name).read_text())

    def test_signal_during_staging_preserves_old_links_and_releases_lock(self):
        process = self.start_slow_update()
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=5)
        self.assert_old()
        self.fixture["delay"] = 0
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_link_changed_by_other_writer_is_preserved(self):
        process = self.start_slow_update()
        link = self.prefix / "bin" / "one"
        replacement = self.prefix / "bin" / "replacement"
        replacement.symlink_to("/different-owner")
        os.replace(replacement, link)
        _, error = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("changed during staging", error)
        self.assertEqual(os.readlink(link), "/different-owner")
        self.assertEqual(self.links()["two"], self.old_targets["two"])

    def test_rollback_restores_old_links_without_registry_calls(self):
        self.assertEqual(self.run_update().returncode, 0)
        receipt = next((self.prefix / ".ai-cli-updates").glob("update-*.json"))
        before = self.log.read_bytes()
        result = self.run_update("--rollback", str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_old()
        self.assertEqual(self.log.read_bytes(), before)

    def test_rollback_refuses_after_another_update(self):
        self.assertEqual(self.run_update().returncode, 0)
        receipt = next((self.prefix / ".ai-cli-updates").glob("update-*.json"))
        self.fixture["versions"] = dict.fromkeys(self.fixture["bins"], "3.0.0")
        self.assertEqual(self.run_update().returncode, 0)
        before = self.links()
        result = self.run_update("--rollback", str(receipt))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.links(), before)

    def test_first_installation_works_without_legacy_tree(self):
        self.prefix = self.root / "fresh"
        self.command[self.command.index("--prefix") + 1] = str(self.prefix)
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2.0.0", (self.prefix / "bin/one").read_text())

    def test_non_symlink_command_is_never_replaced(self):
        replacement = self.prefix / "bin" / "replacement"
        replacement.write_text("unmanaged")
        os.replace(replacement, self.prefix / "bin/one")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "bin/one").read_text(), "unmanaged")
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
