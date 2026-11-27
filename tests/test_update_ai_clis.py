#!/usr/bin/env python3
"""Offline publication/rollback (NIX-524) and bounded generation GC (OPS-723)."""

from contextlib import contextmanager, ExitStack, redirect_stderr, redirect_stdout
import fcntl
import io
import json
import os
from pathlib import Path
import runpy
import shutil
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
import fcntl, json, os, sys, time
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
if fixture.get("lsof_child_canary", True):
    for attempt in range(100):
        try:
            parent, child = json.loads(Path(os.environ["SLEEP_PID"]).read_text())
            os.kill(child, 0)
            if parent == os.getppid():
                break
        except (OSError, ValueError):
            pass
        time.sleep(.01)
    else:
        sys.exit(97)
    sys.stdout.write(f"p{child}\0\nf4\0n{(Path(sys.argv[-1]) / 'lock').resolve()}\0\n")
sys.stdout.write(fixture.get("lsof_output", ""))
sys.stderr.write(fixture.get("lsof_stderr", ""))
sys.exit(fixture.get("lsof_status", 0))
'''
FAKE_SLEEP = r'''#!/usr/bin/env python3
import json, os, time
from pathlib import Path
Path(os.environ["SLEEP_PID"]).write_text(json.dumps([os.getppid(), os.getpid()]))
time.sleep(60)
'''
FAKE_PS = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
fixture = json.loads(Path(os.environ["FIXTURE"]).read_text())
if sys.argv[1:] != ["-axww", "-o", "pid=,args="]:
    sys.exit(98)
if fixture.get("ps_canary", True):
    print(f"{os.getppid()} python updater")
sys.stdout.flush()
sys.stdout.buffer.write(fixture.get("ps_output", "").encode("utf-8", errors="surrogateescape"))
sys.stderr.write(fixture.get("ps_stderr", ""))
sys.exit(fixture.get("ps_status", 0))
'''
REAL_RUN = subprocess.run
REAL_POPEN = subprocess.Popen


@contextmanager
def offline_processes(root):
    """Route Darwin ps to the fixture; reject host scans before spawning."""
    def offline_run(command, *args, **kwargs):
        if command[0] == "/bin/ps":
            command = [str(root / "ps"), *command[1:]]
        return REAL_RUN(command, *args, **kwargs)

    def guarded_popen(command, *args, **kwargs):
        executable = os.fsdecode(kwargs.get("executable") or command[0])
        name = Path(executable).name
        if executable == "/bin/ps":
            raise AssertionError("offline test attempted unredirected /bin/ps")
        if name in ("ps", "lsof"):
            environment = kwargs.get("env")
            path = (os.environ if environment is None else environment).get("PATH", os.defpath)
            resolved = shutil.which(executable, path=path)
            if resolved is None:
                raise FileNotFoundError(executable)
            if Path(resolved).resolve() != (root / name).resolve():
                raise AssertionError(f"offline test attempted non-fixture {name}: {resolved}")
        return REAL_POPEN(command, *args, **kwargs)

    with mock.patch.object(subprocess, "run", side_effect=offline_run):
        with mock.patch.object(subprocess, "Popen", side_effect=guarded_popen):
            yield


# Use the same routing and launch guard in updater subprocesses and in-process
# tests. Keep production's fixed Darwin command observable to command mocks.
OFFLINE_DRIVER = '''
import os, runpy, sys
from pathlib import Path
helpers = runpy.run_path(sys.argv[1])
sys.argv = sys.argv[2:]
with helpers["offline_processes"](Path(os.environ["FIXTURE"]).parent):
    runpy.run_path(sys.argv[0], run_name="__main__")
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
        for name, source in (("sleep", FAKE_SLEEP), ("ps", FAKE_PS)):
            command = self.root / name
            command.write_text(source)
            command.chmod(0o755)
        self.lsof_log = self.root / "lsof-calls"
        self.log = self.root / "calls"
        self.ready = self.root / "ready"
        self.data = self.root / "fixture.json"
        self.env = dict(os.environ, FIXTURE=str(self.data), CALLS=str(self.log),
                        PATH=f"{self.root}:{os.environ['PATH']}",
                        LSOF_CALLS=str(self.lsof_log),
                        SLEEP_PID=str(self.root / "sleep-pid"),
                        READY=str(self.ready), GROK_HOME=str(self.root / "live-grok"))
        self.process_guards = ExitStack()
        self.addCleanup(self.process_guards.close)
        self.process_guards.enter_context(offline_processes(self.root))
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
        return subprocess.run(self.offline_command + list(args), env=self.env,
                              capture_output=True, text=True, timeout=20)

    @property
    def offline_command(self):
        return [sys.executable, "-c", OFFLINE_DRIVER, str(Path(__file__).resolve()),
                *self.command[1:]]

    def test_offline_process_guard_rejects_host_scans(self):
        for command in (["/bin/ps"], ["/usr/sbin/lsof"], ["/usr/bin/ps"]):
            with self.subTest(command=command):
                with mock.patch.object(shutil, "which", return_value=command[0]):
                    with self.assertRaisesRegex(AssertionError, "offline test attempted"):
                        subprocess.Popen(command)

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
        process = subprocess.Popen(self.offline_command, env=self.env, stdout=subprocess.PIPE,
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
        output = (f"p{os.getpid()}\0\nf3\0n{alias / 'lock'}\0\n"
                  f"p12345\0\nf4\0n{alias / 'lock'}\0\n")
        module = runpy.run_path(str(SCRIPT))
        result = subprocess.CompletedProcess([], 1, output, "")
        with lock.open("r+") as descriptor:
            with mock.patch.object(module["subprocess"], "run", return_value=result):
                self.assertFalse(descriptor.closed)
                self.assertEqual(module["lsof_paths"](self.state, 12345),
                                 {os.getpid(): [alias / "lock"], 12345: [alias / "lock"]})

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

    def test_undeclared_live_link_keeps_generation(self):
        self.advance("2.0.0")
        live = self.stage()
        (self.prefix / "bin" / "undeclared").symlink_to(live / "payload")
        stale = self.stage("package-stale000")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        self.assertTrue(live.exists())
        self.assertFalse(stale.exists())

    def test_ps_direct_generation_path_keeps_only_that_generation(self):
        self.advance("2.0.0")
        busy = self.stage()
        stale = self.stage("package-stale000")
        self.fixture["ps_output"] = f"123 node {busy / 'payload'}\n"
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        self.assertTrue(busy.exists())
        self.assertFalse(stale.exists())
        self.fixture["ps_output"] = ""
        self.assertEqual(self.run_update().returncode, 0)
        self.assertFalse(busy.exists())

    def test_ps_launch_link_keeps_all_cli_generations_and_unknown_stages(self):
        # This JS-like process opens no package file: only ps sees its argv.
        oldest = self.advance("2.0.0")
        previous = self.advance("3.0.0")
        unknown = self.stage()
        self.fixture["ps_output"] = f"123 node {self.prefix / 'bin/claude'}\n"
        live = self.advance("4.0.0")
        self.assertTrue(oldest["claude"].exists())
        self.assertFalse(oldest["codex"].exists())
        self.assertTrue(unknown.exists())
        self.assertTrue(all(path.exists() for path in (*previous.values(), *live.values())))
        result = self.run_update()
        self.assertIn("holding all generations of claude", result.stdout)
        self.assertIn("process arguments use its launch link", result.stdout)
        self.fixture["ps_output"] = ""
        result = self.run_update()
        self.assertNotIn("warning", result.stderr)
        self.assertFalse(oldest["claude"].exists())
        self.assertFalse(unknown.exists())

    def test_ps_native_launch_link_keeps_attributed_generation_and_prunes_older(self):
        busy = self.advance("2.0.0")
        obsolete = self.advance("3.0.0")
        self.fixture.update(
            ps_output=f"123 {self.prefix / 'bin/claude'}\n",
            lsof_output=f"p123\0\nftxt\0n{busy['claude'] / 'claude.exe'}\0\n")
        previous = self.advance("4.0.0")
        unknown = self.stage()
        live = self.advance("5.0.0")
        self.assertTrue(busy["claude"].is_dir())
        self.assertFalse(busy["codex"].exists())
        self.assertTrue(all(not path.exists() for path in obsolete.values()))
        self.assertTrue(all(path.is_dir() for path in (*previous.values(), *live.values())))
        self.assertFalse(unknown.exists())
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        self.assertNotIn("holding all generations of claude", result.stdout)

    def configure_pi(self):
        (self.prefix / "bin/claude").rename(self.prefix / "bin/pi")
        self.old_targets["pi"] = self.old_targets.pop("claude")
        self.fixture["bins"]["@test/one"] = "pi"
        self.packages.write_text(json.dumps([
            {"name": name, "version": "latest", "bin": binary}
            for name, binary in self.fixture["bins"].items()
        ]))
        (self.prefix / "bin/pi-rpc").symlink_to(self.prefix / "bin/pi")

    def assert_pi_hold(self, output):
        self.configure_pi()
        oldest = self.advance("2.0.0")
        previous = self.advance("3.0.0")
        unknown = self.stage()
        self.fixture["ps_output"] = output
        live = self.advance("4.0.0")
        self.assertTrue(oldest["pi"].is_dir())
        self.assertFalse(oldest["codex"].exists())
        self.assertTrue(all(path.is_dir() for path in (*previous.values(), *live.values())))
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        self.assertIn("holding all generations of pi", result.stdout)
        self.assertTrue(unknown.exists())
        self.fixture["ps_output"] = ""
        result = self.run_update()
        self.assertNotIn("warning", result.stderr)
        self.assertFalse(oldest["pi"].exists())
        self.assertFalse(unknown.exists())

    def test_ps_pi_launch_link_without_lsof_holds_all_pi_generations(self):
        self.assert_pi_hold(f"123 node {self.prefix / 'bin/pi'}\n")

    def test_ps_pi_process_title_holds_all_pi_generations(self):
        self.assert_pi_hold("123 pi\n")

    def test_ps_pi_rpc_and_path_titles_hold_all_pi_generations(self):
        self.configure_pi()
        oldest = self.advance("2.0.0")
        self.advance("3.0.0")
        self.fixture["versions"] = dict.fromkeys(self.fixture["bins"], "4.0.0")
        for arguments in ("pi --mode rpc", "pi-rpc", "/some/path/pi", "/some/path/pi-rpc"):
            with self.subTest(arguments=arguments):
                self.fixture["ps_output"] = f"124 {arguments}\n"
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("warning", result.stderr)
                self.assertIn("holding all generations of pi", result.stdout)
                self.assertTrue(oldest["pi"].exists())
                self.assertFalse(oldest["codex"].exists())
        self.fixture["ps_output"] = "124 node pi pi-rpc\n125 pi-helper\n126 /some/not-pi\n"
        result = self.run_update()
        self.assertNotIn("warning", result.stderr)
        self.assertNotIn("holding all generations", result.stdout)
        self.assertFalse(oldest["pi"].exists())

    def test_ps_mixed_pid_coverage_holds_all_generations_of_same_cli(self):
        busy = self.advance("2.0.0")
        obsolete = self.advance("3.0.0")
        covered = f"123 {self.prefix / 'bin/claude'}\n"
        uncovered = f"124 {self.prefix / 'bin/claude'}\n"
        self.fixture.update(
            ps_output=covered + uncovered,
            lsof_output=f"p123\0\nftxt\0n{busy['claude'] / 'claude.exe'}\0\n")
        previous = self.advance("4.0.0")
        live = self.advance("5.0.0")
        for output in (covered + uncovered, uncovered + covered):
            with self.subTest(output=output):
                self.fixture["ps_output"] = output
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("warning", result.stderr)
                self.assertIn("holding all generations of claude", result.stdout)
                self.assertTrue(busy["claude"].is_dir())
                self.assertTrue(obsolete["claude"].is_dir())
                self.assertFalse(obsolete["codex"].exists())
                self.assertTrue(all(path.is_dir() for path in (*previous.values(), *live.values())))
        self.fixture["ps_output"] = covered
        result = self.run_update()
        self.assertNotIn("warning", result.stderr)
        self.assertTrue(busy["claude"].is_dir())
        self.assertFalse(obsolete["claude"].exists())

    def test_ps_literal_direct_paths_with_spaces_and_state_alias_keep_generation(self):
        self.advance("2.0.0")
        busy = self.stage()
        alias = self.root / "prefix-alias"
        alias.symlink_to(self.prefix, target_is_directory=True)
        self.command[self.command.index("--prefix") + 1] = str(alias)
        for argument in [str(busy / "payload"), str(alias / self.state.name / busy.name / "payload")]:
            with self.subTest(argument=argument):
                self.fixture["ps_output"] = f"123 node {argument}\n"
                result = self.run_update()
                self.assertNotIn("warning", result.stderr)
                self.assertTrue(busy.exists())

    def test_ps_arbitrary_aliases_are_not_resolved(self):
        oldest = self.advance("2.0.0")
        self.advance("3.0.0")
        alias = self.root / "alias"
        alias.symlink_to(self.prefix / "bin/claude")
        self.fixture["ps_output"] = f"123 node {alias}\n"
        self.advance("4.0.0")
        self.assertFalse(oldest["claude"].exists())
        self.assertFalse(oldest["codex"].exists())

    def test_ps_scan_never_resolves_process_arguments(self):
        self.advance("2.0.0")
        module = runpy.run_path(str(SCRIPT))
        arguments = ["node", "/Volumes/stale-mount/payload", "relative-path", "x" * 10000]
        output = f"{os.getpid()} python updater\n123 {' '.join(arguments)}\n"
        real_resolve = Path.resolve
        def resolve(path, *args, **kwargs):
            self.assertNotIn(str(path), arguments, "process argument accessed on disk")
            return real_resolve(path, *args, **kwargs)
        result = subprocess.CompletedProcess([], 0, output, "")
        with mock.patch.object(Path, "resolve", resolve):
            with mock.patch.object(subprocess, "run", return_value=result):
                self.assertEqual(module["process_generations"](self.prefix, self.state, {}), set())

    def test_ps_unicode_line_separator_does_not_block_prune(self):
        self.advance("2.0.0")
        stale = self.stage()
        self.fixture["ps_output"] = "123 agent pasted\u2028prompt\n"
        result = self.run_update()
        self.assertNotIn("warning", result.stderr)
        self.assertFalse(stale.exists())

    def test_ps_wrapper_with_literal_link_holds_cli(self):
        oldest = self.advance("2.0.0")
        self.advance("3.0.0")
        self.fixture["ps_output"] = f"123 bash -c echo starting; {self.prefix / 'bin/claude'} --mode rpc; wait\n"
        self.advance("4.0.0")
        self.assertTrue(oldest["claude"].exists())
        self.assertFalse(oldest["codex"].exists())

    def test_prune_with_wrapper_only_activation_path(self):
        self.advance("2.0.0")
        module = runpy.run_path(str(SCRIPT))
        runtime = self.root / "runtime-inputs"
        for package, executable, target in (
                ("python3", "python3", Path(sys.executable)),
                ("lsof", "lsof", self.lsof),
                ("coreutils", "sleep", self.root / "sleep"),
                ("procps", "ps", self.root / "ps")):
            directory = runtime / package / "bin"
            directory.mkdir(parents=True)
            (directory / executable).symlink_to(target)
        activation = self.root / "activation-bin"
        activation.mkdir()
        base_path = [runtime / name / "bin" for name in ("python3", "lsof", "coreutils")]
        real_run = subprocess.run
        ps_calls = []
        def scan(command, **kwargs):
            if command[0] in ("ps", "/bin/ps"):
                ps_calls.append(command[0])
                if command[0] == "/bin/ps":
                    # Supply fixture output only; retain and assert the fixed
                    # production command, independent of the activation PATH.
                    return real_run([sys.executable, str(self.root / "ps"), *command[1:]], **kwargs)
            return real_run(command, **kwargs)
        for platform_name, procps, prunes in (("darwin", False, True),
                                              ("linux", True, True),
                                              ("linux", False, False)):
            stale = self.stage()
            directories = base_path + ([runtime / "procps/bin"] if procps else []) + [activation]
            restricted = dict(self.env, PATH=os.pathsep.join(map(str, directories)))
            before = len(self.lsof_log.read_text().splitlines())
            with mock.patch.dict(os.environ, restricted), mock.patch.object(sys, "platform", platform_name):
                with mock.patch.object(subprocess, "run", side_effect=scan):
                    with (self.state / "lock").open("r+") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as stderr:
                            module["prune_generations"](self.prefix, self.state, [])
            self.assertEqual(ps_calls[-1], "/bin/ps" if platform_name == "darwin" else "ps")
            self.assertEqual(len(self.lsof_log.read_text().splitlines()), before + 1)
            self.assertEqual(stale.exists(), not prunes)
            self.assertEqual("warning:" in stderr.getvalue(), not prunes, stderr.getvalue())

    def test_ps_unrelated_argument_content_does_not_block_prune_or_link_hold(self):
        # Each is literal argv content, never a shell program to parse. The
        # invalid byte travels through the fake ps pipe, exercising decoding too.
        for argument in ["'unterminated", "agent's-prompt", "x" * 10000,
                         "invalid-\udcff-byte", "trailing-backslash\\", "nul-\0-byte"]:
            with self.subTest(argument_kind=argument[:20]):
                self.fixture["ps_output"] = ""
                oldest = self.advance("2.0.0")
                previous = self.advance("3.0.0")
                stale = self.stage()
                self.fixture["ps_output"] = (
                    f"123 agent {argument}\n"
                    f"124 node {self.prefix / 'bin/claude'}\n")
                self.fixture["versions"] = dict.fromkeys(self.fixture["bins"], "4.0.0")
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("warning", result.stderr)
                self.assertIn("holding all generations of claude", result.stdout)
                self.assertIn("pruned generation", result.stdout)
                self.assertFalse(oldest["codex"].exists())
                self.assertTrue(oldest["claude"].exists())
                self.assertTrue(all(path.exists() for path in previous.values()))
                # Unknown stages are conservatively held for a linked CLI.
                self.assertTrue(stale.exists())
                self.fixture["ps_output"] = f"123 agent {argument}\n"
                result = self.run_update()
                self.assertNotIn("warning", result.stderr)
                self.assertFalse(stale.exists())

    def test_ps_unbalanced_quote_does_not_block_prune(self):
        self.advance("2.0.0")
        stale = self.stage()
        self.fixture["ps_output"] = "123 agent 'unterminated\n"
        result = self.run_update()
        self.assertNotIn("warning", result.stderr)
        self.assertFalse(stale.exists())

    def test_ps_failure_or_missing_canary_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [], 1)
        for fixture in [dict(ps_status=1), dict(ps_canary=False),
                        dict(ps_stderr="incomplete"), dict(ps_output="not a process\n"),
                        dict(ps_output="123 node path"), dict(ps_output="-1 node path\n"),
                        dict(ps_output="123 node\n123 duplicate\n")]:
            with self.subTest(fixture=fixture):
                self.fixture.update(ps_status=0, ps_canary=True, ps_stderr="", ps_output="")
                self.fixture.update(fixture)
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("warning", result.stderr)
                self.assertTrue(stale.exists())
                self.assertTrue(receipt.exists())

    def test_ps_missing_canary_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        self.fixture.update(ps_canary=False, ps_output="123 node app.js\n")
        result = self.run_update()
        self.assertIn("ps scan missing this process's canary", result.stderr)
        self.assertTrue(stale.exists())

    def test_ps_failure_keeps_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        self.fixture["ps_status"] = 1
        result = self.run_update()
        self.assertIn("ps scan failed or was incomplete", result.stderr)
        self.assertTrue(stale.exists())

    def test_ps_timeout_and_missing_command_keep_everything(self):
        self.advance("2.0.0")
        stale = self.stage()
        module = runpy.run_path(str(SCRIPT))
        real_run = subprocess.run
        for error in [FileNotFoundError("ps"), subprocess.TimeoutExpired("ps", 60)]:
            def scan(command, **kwargs):
                if command[0] in ("ps", "/bin/ps"):
                    raise error
                return real_run(command, **kwargs)
            with self.subTest(error=error), mock.patch.dict(os.environ, self.env):
                with mock.patch.object(module["subprocess"], "run", side_effect=scan):
                    # Skip only lsof here: the ps failure must stop actual GC.
                    with mock.patch.dict(module["prune_generations"].__globals__,
                                         generations_in_use=lambda state: {}):
                        with redirect_stderr(io.StringIO()) as stderr, redirect_stdout(io.StringIO()):
                            module["prune_generations"](self.prefix, self.state, [])
            self.assertIn("warning", stderr.getvalue())
            self.assertTrue(stale.exists())

    def test_lsof_child_canary_required_and_child_reaped(self):
        self.advance("2.0.0")
        stale = self.stage()
        self.fixture["lsof_child_canary"] = False
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("missing child's open-lock canary", result.stderr)
        self.assertTrue(stale.exists())
        module = runpy.run_path(str(SCRIPT))
        for outcome in [subprocess.CompletedProcess([], 2, "", ""),
                        subprocess.TimeoutExpired("lsof", 60)]:
            child = mock.Mock(pid=12345)
            with mock.patch.object(module["subprocess"], "Popen", return_value=child):
                kwargs = dict(side_effect=outcome) if isinstance(outcome, Exception) else dict(return_value=outcome)
                with mock.patch.object(module["subprocess"], "run", **kwargs):
                    with self.assertRaises((module["UpdateError"], subprocess.TimeoutExpired)):
                        module["generations_in_use"](self.state)
            child.terminate.assert_called_once()
            child.wait.assert_called_once_with(timeout=5)

    def test_lsof_outside_state_path_aborts_prune(self):
        self.advance("2.0.0")
        stale = self.stage()
        receipt = self.receipt(1, [], 1)
        self.fixture["lsof_output"] = f"p123\0\nf7\0n{self.root / 'outside'}\0\n"
        result = self.run_update()
        self.assertIn("lsof path outside state directory", result.stderr)
        self.assertTrue(stale.exists())
        self.assertTrue(receipt.exists())

    def test_skipped_and_partial_prune_warn_with_remaining_count_and_size(self):
        self.advance("2.0.0")
        self.stage()
        self.fixture["ps_status"] = 1
        result = self.run_update()
        module = runpy.run_path(str(SCRIPT))
        count, size = module["remaining_generations"](self.state)
        self.assertEqual(count, 3)
        self.assertEqual(result.stderr.count("warning:"), 1)
        self.assertIn(f"{count} generation(s) remain, {size} bytes total", result.stderr)
        with (self.state / "package-dead0000/payload").open("a") as payload:
            payload.write("x" * 100)
        self.assertEqual(module["remaining_generations"](self.state), (count, size + 100))
        # One deletion succeeds before an I/O failure: report only survivors.
        self.stage("package-stale000")
        real_remove = module["shutil"].rmtree
        removed = []
        def partial(path):
            if removed:
                raise OSError("fixture deletion failed")
            real_remove(path)
            removed.append(path)
        with mock.patch.dict(module["prune_generations"].__globals__,
                             generations_in_use=lambda state: {},
                             process_generations=lambda prefix, state, paths_by_pid: set()):
            with mock.patch.object(module["shutil"], "rmtree", side_effect=partial):
                with redirect_stderr(io.StringIO()) as stderr, redirect_stdout(io.StringIO()):
                    module["prune_generations"](self.prefix, self.state, [])
        count, size = module["remaining_generations"](self.state)
        self.assertEqual(len(removed), 1)
        self.assertEqual(stderr.getvalue().count("warning:"), 1)
        self.assertIn(f"{count} generation(s) remain, {size} bytes total", stderr.getvalue())

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
            with mock.patch.object(module["shutil"], "rmtree",
                                   side_effect=PermissionError("fixture refusal")) as remove:
                with redirect_stderr(io.StringIO()) as error, redirect_stdout(io.StringIO()) as output:
                    status = module["main"]()
        remove.assert_called_once_with(stale.resolve())
        self.assertEqual(status, 0)
        self.assertIn("warning", error.getvalue())
        self.assertIn("fixture refusal", error.getvalue())
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
            ('named_cli = tokens[0] == link.name or tokens[0].endswith("/" + link.name)',
             'named_cli = False', "test_ps_pi_process_title_holds_all_pi_generations"),
            ('ps_command = "/bin/ps" if sys.platform == "darwin" else "ps"',
             'ps_command = "ps"', "test_prune_with_wrapper_only_activation_path"),
            ('result.stdout.removesuffix("\\n").split("\\n")',
             'result.stdout.splitlines()', "test_ps_unicode_line_separator_does_not_block_prune"),
            ("tokens = arguments.split()", 'tokens = __import__("shlex").split(arguments)',
             "test_ps_unbalanced_quote_does_not_block_prune"),
            ("kept.add(generation_for(link, state))", "pass",
             "test_live_generation_is_kept_without_receipts"),
            ("kept.add(generation_for(link, state))", "pass",
             "test_undeclared_live_link_keeps_generation"),
            ('if match["previous"] is not None:', 'if False:',
             "test_prune_keeps_live_and_one_previous_per_cli"),
            ("kept.update(generation_for(path, state)\n"
             "                    for paths in paths_by_pid.values() for path in paths)",
             "pass",
             "test_running_process_generation_is_kept_until_later_current_run"),
            ("raise UpdateError(\"lsof scan failed or was incomplete\")", "return {}",
             "test_lsof_failure_keeps_all_generations_and_receipts"),
            ("if not self_canary:", "if False:",
             "test_lsof_rc_one_without_canary_keeps_everything"),
            ("result.returncode not in (0, 1)", "False",
             "test_lsof_failure_keeps_all_generations_and_receipts"),
            ("kept.update(direct_kept)", "pass",
             "test_ps_direct_generation_path_keeps_only_that_generation"),
            ("if paths_by_pid.get(pid):", "if False:",
             "test_ps_native_launch_link_keeps_attributed_generation_and_prunes_older"),
            ("if len(names) != 1 or None in held.values() or names.intersection(held.values()):",
             "if False:", "test_ps_launch_link_keeps_all_cli_generations_and_unknown_stages"),
            ("if not ps_canary:", "if False:",
             "test_ps_missing_canary_keeps_everything"),
            ("if not child_canary:", "if False:",
             "test_lsof_child_canary_required_and_child_reaped"),
            ('raise UpdateError("lsof path outside state directory")', 'pass',
             "test_lsof_outside_state_path_aborts_prune"),
            ('remaining = f"{count} generation(s) remain, {size} bytes total"',
             'remaining = ""', "test_skipped_and_partial_prune_warn_with_remaining_count_and_size"),
            ('raise UpdateError("ps scan failed or was incomplete")', 'return set()',
             "test_ps_failure_keeps_everything"),
            ('and not path.is_symlink() and path.is_dir() and path not in kept',
             'and path.is_dir() and path not in kept',
             "test_symlink_named_like_generation_is_untouched"),
            ('if (re.fullmatch(r"package-[A-Za-z0-9_]{8}", path.name)', 'if (True',
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
