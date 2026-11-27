#!/usr/bin/env python3
"""Offline publication/rollback (NIX-524) and bounded generation GC (OPS-723)."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


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
FAKE_LSOF = r'''#!/usr/bin/env python3
import fcntl, json, os, sys
from pathlib import Path
fixture = json.loads(Path(os.environ["FIXTURE"]).read_text())
with open(os.environ["LSOF_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
# A scan outside the updater's existing lock must fail the fixture.
with open(Path(sys.argv[-1]) / "lock", "r+") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        sys.exit(98)
if fixture.get("lsof_canary", True):
    pid = os.getppid() + (1 if fixture.get("lsof_other_pid") else 0)
    sys.stdout.write(f"p{pid}\0\nf3\0n{(Path(sys.argv[-1]) / 'lock').resolve()}\0\n")
sys.stdout.write(fixture.get("lsof_output", ""))
sys.stderr.write(fixture.get("lsof_stderr", ""))
sys.exit(fixture.get("lsof_status", 0))
'''


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-ai-clis-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / "npm global"
        (self.prefix / "bin").mkdir(parents=True)
        self.fixture = {"versions": {"@test/one": "2.0.0", "@test/two": "2.0.0"},
                        "bins": {"@test/one": "claude", "@test/two": "codex"}}
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
        self.lsof = self.root / "lsof"
        self.lsof.write_text(FAKE_LSOF)
        self.lsof.chmod(0o755)
        self.lsof_log = self.root / "lsof-calls"
        self.log = self.root / "calls"
        self.ready = self.root / "ready"
        self.data = self.root / "fixture.json"
        self.env = dict(os.environ, FIXTURE=str(self.data), CALLS=str(self.log),
                        PATH=f"{self.root}:{os.environ['PATH']}",
                        LSOF_CALLS=str(self.lsof_log),
                        READY=str(self.ready), GROK_HOME=str(self.root / "live-grok"))
        self.command = [sys.executable, str(SCRIPT), "--prefix", str(self.prefix),
                        "--packages", str(self.packages), "--allow-scripts",
                        str(self.approvals)]
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
        self.assertEqual(self.links()["claude"], self.old_targets["claude"])

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
        Path(self.old_targets["claude"]).write_text("#!/bin/sh\nexit 1\n")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.installs()), 1)
        self.assertNotEqual(self.links()["claude"], self.old_targets["claude"])

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
        self.assertEqual(self.links()["claude"], self.old_targets["claude"])
        self.assertIn("@test/one@1.0.0", self.calls()[0]["args"])

    def test_unsupported_package_does_not_block_other_packages(self):
        self.fixture["unsupported"] = ["@test/one"]
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.links()["claude"], self.old_targets["claude"])
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
        link = self.prefix / "bin" / "claude"
        replacement = self.prefix / "bin" / "replacement"
        replacement.symlink_to("/different-owner")
        os.replace(replacement, link)
        _, error = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("changed during staging", error)
        self.assertEqual(os.readlink(link), "/different-owner")
        self.assertEqual(self.links()["codex"], self.old_targets["codex"])

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
        self.assertIn("2.0.0", (self.prefix / "bin/claude").read_text())

    def test_non_symlink_command_is_never_replaced(self):
        replacement = self.prefix / "bin" / "replacement"
        replacement.write_text("unmanaged")
        os.replace(replacement, self.prefix / "bin/claude")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / "bin/claude").read_text(), "unmanaged")
        self.assertFalse(self.log.exists())

    @property
    def state(self):
        return self.prefix / ".ai-cli-updates"

    def stage(self, name="package-dead0000"):
        path = self.state / name
        path.mkdir(parents=True)
        (path / "payload").write_text("stale staging")
        return path

    def advance(self, version):
        self.fixture["versions"] = dict.fromkeys(self.fixture["bins"], version)
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        return {name: Path(target).parents[1] for name, target in self.links().items()}

    def receipt(self, number, records, timestamp):
        path = self.state / f"update-{number:032x}.json"
        path.write_text(json.dumps({"schema": 1, "prefix": str(self.prefix), "updates": records}))
        os.utime(path, ns=(timestamp, timestamp))
        return path

    def test_prune_keeps_live_and_one_previous_per_cli(self):
        oldest = self.advance("2.0.0")
        previous = self.advance("3.0.0")
        stale = self.stage()
        live = self.advance("4.0.0")
        for path in oldest.values():
            self.assertFalse(path.exists())
        self.assertFalse(stale.exists())
        for path in (*previous.values(), *live.values()):
            self.assertTrue(path.is_dir())
        self.assertEqual(len(list(self.state.glob("package-*"))), 4)
        # Legacy packages and the lock are outside the candidate set.
        for target in self.old_targets.values():
            self.assertIn("1.0.0", Path(target).read_text())
        self.assertTrue((self.state / "lock").is_file())

    def test_current_run_prunes_staging_and_logs_once_per_generation(self):
        self.advance("2.0.0")
        stale = self.stage()
        failed = self.stage("package-failed00")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())
        self.assertFalse(failed.exists())
        self.assertEqual(result.stdout.count("pruned generation "), 2)
        self.assertIn("pruned 2 generation(s) total", result.stdout)
        calls = [json.loads(line) for line in self.lsof_log.read_text().splitlines()]
        self.assertEqual(len(calls), 2)  # one scan per locked run
        self.assertEqual(calls[-1], ["-w", "-nP", "-F0pfn", "+D", str(self.state.resolve())])

    def test_running_process_generation_is_kept_until_later_current_run(self):
        self.advance("2.0.0")
        busy = self.stage()
        # Machine-format lsof path includes spaces from the temporary prefix.
        self.fixture["lsof_output"] = f"p123\0\nf7\0n{busy / 'payload'}\0\n"
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(busy.exists())
        self.fixture["lsof_output"] = ""
        self.assertEqual(self.run_update().returncode, 0)
        self.assertFalse(busy.exists())

    def test_lsof_rc_one_with_canary_prunes_but_keeps_in_use(self):
        self.advance("2.0.0")
        busy = self.stage()
        stale = self.stage("package-stale000")
        self.fixture.update(lsof_status=1,
                            lsof_output=f"p123\0\nf7\0n{busy / 'payload'}\0\n")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        self.assertTrue(busy.exists())
        self.assertFalse(stale.exists())

    def test_lsof_rc_one_without_canary_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [], 1)
        self.fixture.update(lsof_status=1, lsof_canary=False,
                            lsof_output=f"p123\0\nf7\0n{stale / 'payload'}\0\n")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning", result.stderr)
        self.assertIn("missing this process's open-lock canary", result.stderr)
        self.assertTrue(stale.exists())
        self.assertTrue(receipt.exists())

    def test_lsof_canary_from_another_pid_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [], 1)
        self.fixture.update(lsof_status=1, lsof_other_pid=True)
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("missing this process's open-lock canary", result.stderr)
        self.assertTrue(stale.exists())
        self.assertTrue(receipt.exists())

    def test_lsof_stderr_with_canary_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [], 1)
        self.fixture.update(lsof_status=1, lsof_stderr="lsof: incomplete scan")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning", result.stderr)
        self.assertTrue(stale.exists())
        self.assertTrue(receipt.exists())

    def test_lsof_canary_compares_resolved_paths(self):
        self.state.mkdir()
        lock = self.state / "lock"
        lock.touch()
        alias = self.root / "state-alias"
        alias.symlink_to(self.state, target_is_directory=True)
        output = f"p{os.getpid()}\0\nf3\0n{alias / 'lock'}\0\n"
        module = runpy.run_path(str(SCRIPT))
        result = subprocess.CompletedProcess([], 1, output, "")
        with lock.open("r+") as descriptor:
            with mock.patch.object(module["subprocess"], "run", return_value=result):
                self.assertFalse(descriptor.closed)
                self.assertEqual(module["generations_in_use"](self.state), [alias / "lock"])

    def test_lsof_failure_keeps_all_generations_and_receipts(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [], 1)
        self.fixture["lsof_status"] = 2
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning", result.stderr)
        self.assertTrue(stale.exists())
        self.assertTrue(receipt.exists())

    def test_lsof_missing_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        module = runpy.run_path(str(SCRIPT))
        with mock.patch.object(module["subprocess"], "run", side_effect=FileNotFoundError("lsof")):
            with redirect_stderr(io.StringIO()) as error, redirect_stdout(io.StringIO()):
                module["prune_generations"](self.prefix, self.state, json.loads(self.packages.read_text()))
        self.assertTrue(stale.exists())
        self.assertIn("warning", error.getvalue())

    def test_lsof_timeout_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        module = runpy.run_path(str(SCRIPT))
        with mock.patch.object(module["subprocess"], "run",
                               side_effect=subprocess.TimeoutExpired("lsof", 60)):
            with redirect_stderr(io.StringIO()) as error, redirect_stdout(io.StringIO()):
                module["prune_generations"](self.prefix, self.state, json.loads(self.packages.read_text()))
        self.assertTrue(stale.exists())
        self.assertIn("warning", error.getvalue())

    def test_lsof_unparsable_or_incomplete_scan_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        for output, error in [
            ("COMMAND PID NAME\n", ""),
            ("p123\0\nf7\0nrelative/path\0\n", ""),
            (f"p123\0\nf7\0n{stale}/payload", ""),
            ("p123\0\nf7\0\n", ""),
            ("p123\0\n", ""),
            ("p123\0\np124\0\nf7\0n/tmp/fixture\0\n", ""),
            (f"p123\0\nf7\0n{stale}/escaped^Jname\0\n", ""),
            ("", "lsof: incomplete scan"),
        ]:
            with self.subTest(output=output, error=error):
                self.fixture.update(lsof_output=output, lsof_stderr=error)
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("warning", result.stderr)
                self.assertTrue(stale.exists())

    def test_live_generation_is_kept_without_receipts(self):
        live = self.advance("2.0.0")
        for path in self.state.glob("update-*.json"):
            path.unlink()
        stale = self.stage()
        self.assertEqual(self.run_update().returncode, 0)
        self.assertFalse(stale.exists())
        for path in live.values():
            self.assertTrue(path.is_dir())

    def test_symlink_named_like_generation_is_untouched(self):
        self.advance("2.0.0")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "payload").write_text("unmanaged")
        link = self.state / "package-symlink0"
        link.symlink_to(outside, target_is_directory=True)
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)  # must never even attempt rmtree on the link
        self.assertTrue(link.is_symlink())
        self.assertEqual((outside / "payload").read_text(), "unmanaged")

    def test_nonmatching_names_files_and_nested_directories_are_untouched(self):
        self.advance("2.0.0")
        paths = [self.stage(name) for name in (
            "package-short", "package-too_long0", "package-hyphen-0", "unmanaged",
            "unmanaged/package-nested00")]
        ordinary = self.state / "package-file0000"
        ordinary.write_text("not a directory")
        self.assertEqual(self.run_update().returncode, 0)
        for path in paths:
            self.assertTrue(path.is_dir())
        self.assertEqual(ordinary.read_text(), "not a directory")

    def test_check_and_rollback_never_prune_existing_state(self):
        self.advance("2.0.0")
        receipt = next(self.state.glob("update-*.json"))
        stale = self.stage()
        before = self.lsof_log.read_bytes()
        for args in [("--check",), ("--rollback", str(receipt))]:
            result = self.run_update(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(stale.exists())
            self.assertEqual(self.lsof_log.read_bytes(), before)
        self.assert_old()

    def test_newest_receipt_rollback_works_after_pruning(self):
        oldest = self.advance("2.0.0")
        previous = self.advance("3.0.0")
        previous_links = self.links()
        self.advance("4.0.0")
        receipt = next(path for path in self.state.glob("update-*.json")
                       if read_receipt_version(path) == "4.0.0")
        self.assertTrue(all(not path.exists() for path in oldest.values()))
        result = self.run_update("--rollback", str(receipt))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.links(), previous_links)
        self.assertTrue(all(path.exists() for path in previous.values()))

    def test_only_newest_matching_receipt_selects_previous(self):
        self.advance("2.0.0")
        target = self.links()["claude"]
        older = self.stage("package-older000")
        newest = self.stage("package-newest00")
        stale = self.receipt(1, [{"bin": "claude", "target": target,
                                  "previous": str(older / "payload")}], 1)
        selected = self.receipt(2, [{"bin": "claude", "target": target,
                                     "previous": str(newest / "payload")}], time.time_ns() + 10**9)
        mismatched = self.receipt(3, [{"bin": "claude", "target": str(older / "payload"),
                                      "previous": str(older / "payload")}], time.time_ns() + 2 * 10**9)
        self.assertEqual(self.run_update().returncode, 0)
        self.assertFalse(older.exists())
        self.assertTrue(newest.exists())
        self.assertTrue(selected.exists())
        self.assertFalse(mismatched.exists())
        # An old receipt referencing the retained live generation remains useful.
        self.assertTrue(stale.exists())

    def test_receipts_referencing_no_retained_generation_are_removed(self):
        self.advance("2.0.0")
        self.advance("3.0.0")
        self.advance("4.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [{"bin": "claude", "target": str(stale / "payload"),
                                  "previous": None}], 1)
        self.assertEqual(self.run_update().returncode, 0)
        self.assertFalse(receipt.exists())
        self.advance("5.0.0")
        self.assertEqual({read_receipt_version(path) for path in self.state.glob("update-*.json")},
                         {"4.0.0", "5.0.0"})

    def test_prune_error_after_publication_warns_and_exits_zero(self):
        stale = self.stage()
        self.data.write_text(json.dumps(self.fixture))
        module = runpy.run_path(str(SCRIPT))
        with mock.patch.dict(os.environ, self.env), mock.patch.object(sys, "argv", self.command[1:]):
            with mock.patch.object(module["shutil"], "rmtree", side_effect=PermissionError("fixture refusal")):
                with redirect_stderr(io.StringIO()) as error, redirect_stdout(io.StringIO()) as output:
                    status = module["main"]()
        self.assertEqual(status, 0)
        self.assertIn("warning", error.getvalue())
        self.assertIn("published", output.getvalue())
        self.assertTrue(stale.exists())
        for binary in self.old_targets:
            self.assertIn("2.0.0", (self.prefix / "bin" / binary).read_text())

    def test_malformed_receipt_keeps_all_generations(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.state / f"update-{1:032x}.json"
        for data in ["{", "[]", '{"schema":1}',
                     json.dumps({"schema": 1, "prefix": str(self.prefix), "updates": [{}]})]:
            with self.subTest(data=data):
                receipt.write_text(data)
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(stale.exists())
                self.assertIn("warning", result.stderr)

    def test_prune_guard_removal_mutants_must_fail(self):
        original = SCRIPT.read_text()
        cases = [
            ("kept.add(generation_for(link, state))", "pass",
             "test_live_generation_is_kept_without_receipts"),
            ('if match["previous"] is not None:', 'if False:',
             "test_prune_keeps_live_and_one_previous_per_cli"),
            ("kept.update(generation_for(path, state) for path in generations_in_use(state))",
             "generations_in_use(state)",
             "test_running_process_generation_is_kept_until_later_current_run"),
            ("raise UpdateError(\"lsof scan failed or was incomplete\")", "return []",
             "test_lsof_failure_keeps_all_generations_and_receipts"),
            ("if not self_canary:", "if False:",
             "test_lsof_rc_one_without_canary_keeps_everything"),
            ("result.returncode not in (0, 1)", "False",
             "test_lsof_failure_keeps_all_generations_and_receipts"),
            ('and not path.is_symlink() and path.is_dir() and path not in kept',
             'and path.is_dir() and path not in kept',
             "test_symlink_named_like_generation_is_untouched"),
            ('re.fullmatch(r"package-[A-Za-z0-9_]{8}", path.name)', 'True',
             "test_nonmatching_names_files_and_nested_directories_are_untouched"),
            ("receipt.unlink()", "pass",
             "test_receipts_referencing_no_retained_generation_are_removed"),
            ('receipts.sort(key=lambda entry: (entry[0], entry[1].name), reverse=True)',
             'receipts.sort(key=lambda entry: (entry[0], entry[1].name), reverse=False)',
             "test_only_newest_matching_receipt_selects_previous"),
            (' and item["target"] == current', '',
             "test_only_newest_matching_receipt_selects_previous"),
        ]
        for number, (old, new, contract) in enumerate(cases):
            with self.subTest(contract=contract):
                self.assertEqual(original.count(old), 1, "missing mutation anchor")
                mutant = self.root / f"mutant-{number}.py"
                mutant.write_text(original.replace(old, new))
                with mock.patch.object(sys.modules[__name__], "SCRIPT", mutant):
                    result = unittest.TestResult()
                    UpdateTests(contract).run(result)
                self.assertFalse(result.errors, result.errors)
                self.assertEqual(len(result.failures), 1, "guard-removal mutant survived")


def read_receipt_version(path):
    return json.loads(path.read_text())["updates"][0]["version"]


if __name__ == "__main__":
    unittest.main()
