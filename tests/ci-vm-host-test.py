#!/usr/bin/env python3
"""Offline Darwin policy checks against the real host helper, without host CLIs."""

from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import io
import json
import os
import runpy
import tempfile
from pathlib import Path
import struct
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


source = Path(__file__).resolve().parents[1] / "hosts/mbp2607/files/ci-vm/host.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ci_vm_host", source)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


heavy_spec = importlib.util.spec_from_file_location("heavy_lock", source.with_name("heavy-lock.py"))
heavy = importlib.util.module_from_spec(heavy_spec)
heavy_spec.loader.exec_module(heavy)


class HeavyLockTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "ci-locks" / "mbp2607-heavy.lock.d"
        self.now = 20000

    def acquire(self):
        return heavy.operate("acquire", self.path, os.getpid(), self.now,
                             "https://github.com/fixture/repo/actions/runs/1")

    def fixture(self, owner="papp-night", pid=99999999, age=10801):
        self.acquire()
        data = json.loads((self.path / "owner.json").read_text())
        data.update(owner=owner, pid=pid, started_at=heavy.utc(self.now - age))
        heavy.write_owner(self.path, data)

    def test_atomic_schema_parent_and_handoff(self):
        replace = heavy.os.replace
        observed = []
        def check_replace(src, dst):
            self.assertEqual(Path(src).stat().st_mode & 0o777, 0o644)
            data = json.loads(Path(src).read_text())
            self.assertEqual(set(data), {"schema", "owner", "pid", "started_at", "job_url", "host"})
            self.assertEqual(data["schema"], "mbp2607-heavy-lock.v1")
            self.assertEqual(data["host"], "mbp2607")
            self.assertTrue(data["started_at"].endswith("Z"))
            observed.append(data["pid"])
            replace(src, dst)
        with patch.object(heavy.os, "replace", side_effect=check_replace):
            self.assertEqual(self.acquire()["transitions"], ["acquired"])
            heavy.operate("handoff", self.path, os.getpid(), self.now, "", 1234)
        self.assertEqual(observed, [os.getpid(), 1234])
        self.assertEqual(self.path.parent.stat().st_mode & 0o7777, 0o1777)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.path / "owner.json").stat().st_mode & 0o777, 0o644)
        self.assertEqual(list(self.path.iterdir()), [self.path / "owner.json"])

    def test_stale_requires_both_dead_and_old(self):
        for pid, age, stale in [(99999999,10801,True), (os.getpid(),10801,False),
                                (99999999,10800,False), (99999999,100,False)]:
            with self.subTest(pid=pid, age=age), tempfile.TemporaryDirectory() as directory:
                self.path = Path(directory) / "ci-locks" / "mbp2607-heavy.lock.d"
                self.fixture(pid=pid, age=age)
                result = self.acquire()
                self.assertEqual(result["busy"], not stale)
                quarantines = list(self.path.parent.glob("*.stale-*"))
                self.assertEqual(len(quarantines), int(stale))
                if stale:
                    self.assertEqual(json.loads((quarantines[0] / "owner.json").read_text())["owner"], "papp-night")
                    self.assertTrue(any(t.startswith("stale-broken ") for t in result["transitions"]))

    def test_missing_and_malformed_use_mtime(self):
        for text in (None, "{bad json", '{}'):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as directory:
                self.path = Path(directory) / "ci-locks" / "mbp2607-heavy.lock.d"
                self.path.mkdir(parents=True)
                if text is not None: (self.path / "owner.json").write_text(text)
                os.utime(self.path, (self.now - 100, self.now - 100))
                self.assertTrue(self.acquire()["busy"])
                os.utime(self.path, (self.now - 10801, self.now - 10801))
                self.assertFalse(self.acquire()["busy"])

    def test_production_cli_uses_constant_path_and_rejects_path_argument(self):
        script = source.with_name("heavy-lock.py")
        output = io.StringIO()
        with patch.dict(os.environ, {"CI_VM_HEAVY_LOCK": str(self.path)}), \
                patch.object(sys, "argv", [str(script), "acquire", str(os.getpid()), str(self.now),
                                          "https://github.com/fixture/repo/actions"]), \
                patch.object(Path, "exists", return_value=False), \
                patch.object(Path, "mkdir", autospec=True, side_effect=PermissionError) as mkdir, \
                redirect_stdout(output):
            runpy.run_path(str(script), run_name="__main__")
        self.assertEqual(mkdir.call_args.args[0], Path(heavy.LOCK_PATH).parent)
        self.assertTrue(json.loads(output.getvalue())["busy"])
        with patch.object(sys, "argv", [str(script), "acquire", str(self.path),
                                       str(os.getpid()), str(self.now)]), \
                patch.object(Path, "mkdir") as mkdir, redirect_stderr(io.StringIO()), \
                self.assertRaises(SystemExit) as error:
            runpy.run_path(str(script), run_name="__main__")
        self.assertEqual(error.exception.code, 1)
        mkdir.assert_not_called()

    def test_unreadable_record_and_directory_never_stale(self):
        self.fixture(pid=os.getpid())
        record = self.path / "owner.json"
        os.utime(self.path, (self.now - 10801, self.now - 10801))
        record.chmod(0)
        try:
            self.assertTrue(self.acquire()["busy"])
            self.assertEqual(list(self.path.parent.glob("*.stale-*")), [])
        finally:
            record.chmod(0o644)
        self.path.chmod(0)
        try:
            self.assertTrue(self.acquire()["busy"])
        finally:
            self.path.chmod(0o755)

    def test_missing_record_dead_holder_uses_old_directory_mtime(self):
        self.fixture()
        (self.path / "owner.json").unlink()
        os.utime(self.path, (self.now - 10801, self.now - 10801))
        self.assertFalse(self.acquire()["busy"])
        self.assertEqual(len(list(self.path.parent.glob("*.stale-*"))), 1)

    def test_io_errors_and_sticky_parent_denial_are_busy(self):
        self.fixture()
        for error in (PermissionError, OSError):
            with self.subTest(error=error), patch.object(Path, "read_text", side_effect=error):
                self.assertTrue(self.acquire()["busy"])
        with patch.object(Path, "rename", side_effect=PermissionError):
            self.assertTrue(self.acquire()["busy"])
        with patch.object(Path, "mkdir", side_effect=PermissionError):
            self.assertTrue(self.acquire()["busy"])
        with patch.object(heavy.os, "scandir", side_effect=PermissionError):
            self.assertTrue(self.acquire()["busy"])

    def test_changed_stale_rename_blocks_future_boots(self):
        self.fixture()
        original = heavy.same
        def changed(path, stat, owner):
            return False if ".stale-" in path.name else original(path, stat, owner)
        with patch.object(heavy, "same", side_effect=changed):
            with self.assertRaisesRegex(RuntimeError, "boots blocked"):
                self.acquire()
        self.assertFalse(self.path.exists())
        self.assertTrue(self.acquire()["busy"])
        self.assertFalse(self.path.exists())

    def test_running_lock_recovery(self):
        result = heavy.operate("retain", self.path, os.getpid(), self.now,
                               "https://github.com/fixture/repo/actions", os.getpid())
        self.assertFalse(result["busy"])
        self.assertEqual(result["owner"]["pid"], os.getpid())
        self.fixture(owner=heavy.OWNER)
        result = heavy.operate("retain", self.path, os.getpid(), self.now,
                               "https://github.com/fixture/repo/actions", os.getpid())
        self.assertFalse(result["busy"])
        self.assertEqual(result["owner"]["pid"], os.getpid())
        self.fixture()
        self.assertTrue(heavy.operate("retain", self.path, os.getpid(), self.now,
                                     "https://github.com/fixture/repo/actions", os.getpid())["busy"])

    def test_must_fail_unreadable_and_missing_record_mutants(self):
        original = source.with_name("heavy-lock.py").read_text()
        for old, new, contract in [
            ('    except FileNotFoundError:\n        # A disappearing directory',
             '    except OSError:\n        # A disappearing directory',
             "test_unreadable_record_and_directory_never_stale"),
            ('    except FileNotFoundError:\n        # A disappearing directory',
             '    except PermissionError:\n        # A disappearing directory',
             "test_missing_record_dead_holder_uses_old_directory_mtime")]:
            self.assertEqual(original.count(old), 1)
            namespace = {"__name__": "mutant"}
            exec(compile(original.replace(old, new), "heavy-lock-mutant.py", "exec"), namespace)
            with patch.object(heavy, "operate", namespace["operate"]):
                result = unittest.TestResult()
                HeavyLockTest(contract).run(result)
                self.assertFalse(result.wasSuccessful(), "record-read mutant survived")

    def test_invalid_record_with_live_pid_is_retained(self):
        self.acquire()
        (self.path / "owner.json").write_text(json.dumps({"pid": os.getpid()}))
        os.utime(self.path, (self.now - 10801, self.now - 10801))
        self.assertTrue(self.acquire()["busy"])

    def test_handoff_refuses_missing_or_changed_owner(self):
        with self.assertRaisesRegex(RuntimeError, "disappeared"):
            heavy.operate("handoff", self.path, os.getpid(), self.now, "", 1234)
        self.fixture(pid=os.getpid())
        with self.assertRaisesRegex(RuntimeError, "ownership changed"):
            heavy.operate("handoff", self.path, os.getpid(), self.now, "", 1234)

    def test_own_residue_and_pid_reuse(self):
        self.fixture(owner=heavy.OWNER, age=1)
        self.assertEqual(self.acquire()["transitions"], ["residue-released", "acquired"])
        # Same PID is a verified hostagent: retain even with stopped status.
        result = heavy.operate("acquire", self.path, os.getpid(), self.now, "https://github.com/fixture/repo/actions", os.getpid())
        self.assertTrue(result["busy"])
        # A live unrelated/reused PID is residue only after caller verified stopped.
        self.assertEqual(self.acquire()["transitions"], ["residue-released", "acquired"])

    def test_papp_optional_fields_preserve_identity_and_start(self):
        for suffix in ("Z", "+00:00"):
            for url in (None, "", "http://example.test/papp", 17):
                with self.subTest(suffix=suffix, url=url):
                    self.now += 1
                    self.fixture(pid=os.getpid())
                    data = json.loads((self.path / "owner.json").read_text())
                    data.update(started_at=heavy.utc(self.now - 10801)[:-1] + ".123456" + suffix, job_url=url)
                    heavy.write_owner(self.path, data)
                    _, owner, started = heavy.snapshot(self.path)
                    self.assertEqual(owner["owner"], "papp-night")
                    self.assertEqual(owner["pid"], os.getpid())
                    self.assertEqual(owner["job_url"], "unknown")
                    self.assertAlmostEqual(started, self.now - 10801 + .123456)
                    self.assertTrue(self.acquire()["busy"])
                    data["pid"] = 99999999
                    heavy.write_owner(self.path, data)
                    self.assertFalse(self.acquire()["busy"])

    def test_unknown_pid_is_never_dead_by_itself(self):
        for pid in (None, 0, -1, True, "123", 1.5):
            with self.subTest(pid=pid):
                self.fixture(pid=99999999)
                data = json.loads((self.path / "owner.json").read_text())
                data["pid"] = pid
                heavy.write_owner(self.path, data)
                self.assertTrue(self.acquire()["busy"])

    def test_start_fallback_uses_mtime_without_losing_owner(self):
        self.fixture()
        data = json.loads((self.path / "owner.json").read_text())
        data.update(started_at="bad", job_url=None)
        heavy.write_owner(self.path, data)
        os.utime(self.path, (self.now - 100, self.now - 100))
        self.assertTrue(self.acquire()["busy"])
        _, owner, _ = heavy.snapshot(self.path)
        self.assertEqual(owner["owner"], "papp-night")
        os.utime(self.path, (self.now - 10801, self.now - 10801))
        self.assertFalse(self.acquire()["busy"])

    def test_live_hostagent_prevents_residue_and_stale_release(self):
        self.fixture(owner=heavy.OWNER, age=20000)
        for action in ("residue", "acquire"):
            result = heavy.operate(action, self.path, os.getpid(), self.now,
                                   "https://github.com/fixture/repo/actions", os.getpid())
            self.assertEqual(result["transitions"], [])
            self.assertTrue(self.path.exists())

    def test_release_race_during_acquire_retries(self):
        original = heavy.snapshot
        def disappeared(path):
            if not hasattr(disappeared, "done"):
                disappeared.done = True
                (path / "owner.json").unlink()
                path.rmdir()
                raise FileNotFoundError()
            return original(path)
        self.fixture()
        with patch.object(heavy, "snapshot", side_effect=disappeared):
            self.assertEqual(self.acquire()["transitions"], ["acquired"])

    def test_must_fail_parsing_and_live_hostagent_mutants(self):
        original = source.with_name("heavy-lock.py").read_text()
        for old, new, contract in [
            ('value = datetime.datetime.fromisoformat(owner["started_at"].replace("Z", "+00:00"))',
             'value = datetime.datetime.strptime(owner["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)',
             "test_papp_optional_fields_preserve_identity_and_start"),
            (' and hostagent == 0', '', "test_live_hostagent_prevents_residue_and_stale_release")]:
            self.assertIn(old, original)
            namespace = {"__name__": "mutant"}
            exec(compile(original.replace(old, new), "heavy-lock-mutant.py", "exec"), namespace)
            with patch.object(heavy, "operate", namespace["operate"]), patch.object(heavy, "snapshot", namespace["snapshot"]):
                result = unittest.TestResult()
                HeavyLockTest(contract).run(result)
                self.assertFalse(result.wasSuccessful(), "heavy lock mutant survived")

    def test_release_requires_own_owner_and_exact_pid(self):
        self.fixture(pid=os.getpid())
        self.assertEqual(heavy.operate("release", self.path, os.getpid(), self.now)["transitions"], [])
        self.assertTrue(self.path.exists())
        data = json.loads((self.path / "owner.json").read_text())
        data["owner"] = heavy.OWNER
        heavy.write_owner(self.path, data)
        self.assertEqual(heavy.operate("release", self.path, 1234, self.now)["transitions"], [])
        self.assertEqual(heavy.operate("release", self.path, os.getpid(), self.now)["transitions"], ["released"])
        self.assertTrue(self.path.parent.exists())
        self.assertFalse(self.path.exists())

    def test_must_fail_stale_or_and_foreign_release_mutants(self):
        original = source.with_name("heavy-lock.py").read_text()
        for old, new, contract in [
            ('dead(owner) and now - started > 10800',
             'dead(owner) or now - started > 10800', "test_stale_requires_both_dead_and_old"),
            ('owner.get("owner") != OWNER or not same(path, stat, owner)',
             'not same(path, stat, owner)', "test_release_requires_own_owner_and_exact_pid")]:
            self.assertEqual(original.count(old), 1)
            namespace = {"__name__": "mutant"}
            exec(compile(original.replace(old, new), "heavy-lock-mutant.py", "exec"), namespace)
            with patch.object(heavy, "operate", namespace["operate"]):
                result = unittest.TestResult()
                HeavyLockTest(contract).run(result)
                self.assertFalse(result.wasSuccessful(), "heavy lock mutant survived")


class StandardPolicyTest(unittest.TestCase):
    def setUp(self):
        self.pidfile = "/fixture/colima/_lima/colima-ci/ha.pid"
        self.flags = {101: 0, 202: 0, 303: 0}
        self.owners = {101: 501, 202: 501, 303: 501}
        self.executables = {101: "limactl", 202: "com.apple.Virtualization.VirtualMachine",
                            303: "com.apple.Virtualization.VirtualMachine"}
        self.clears = []
        self.stuck = False
        self.unreadable = None
        self.domain = "202 0 com.apple.Virtualization.VirtualMachine.ci\n303 0 com.apple.Virtualization.VirtualMachine.other\n"
        self.disks = {202: "diffdisk", 303: "other-disk"}
        self.args = f"limactl hostagent --pidfile {self.pidfile} ci"

        def info(pid, flavor, arg, buf, size):
            self.assertEqual((flavor, arg, size), (3, 0, 136))
            if pid == self.unreadable:
                return 0
            buf.value = struct.pack("6I", self.flags[pid], 0, 0, pid, 1, self.owners[pid])
            return size

        def executable(pid, buf, size):
            buf.value = ("/fixture/" + self.executables[pid]).encode()
            return len(buf.value)

        def output(command, **kwargs):
            self.assertEqual(kwargs, {"text": True})
            if command == ["/bin/ps", "-p", "101", "-o", "command="]:
                return self.args
            if command == ["/bin/launchctl", "print", "pid/101"]:
                return self.domain
            self.assertEqual(command[:8], ["/usr/sbin/lsof", "-n", "-P", "-b", "-w", "-a", "-p", command[7]])
            self.assertEqual(command[8:], ["-Fn"])
            return "n" + str(Path(self.pidfile).parent / self.disks[int(command[7])]) + "\n"

        def clear(command, **kwargs):
            self.assertEqual(kwargs, {"check": True})
            pid = int(command[-1])
            self.assertEqual(command, ["/usr/sbin/taskpolicy", "-B", "-p", str(pid)])
            self.assertIn(pid, (101, 202))
            self.clears.append(pid)
            if not self.stuck:
                self.flags[pid] &= ~0x10000
            if self.unreadable == "after-clear":
                self.unreadable = pid

        libproc = SimpleNamespace(proc_pidinfo=Mock(side_effect=info),
                                  proc_pidpath=Mock(side_effect=executable))
        for p in [patch.object(host, "PIDFILE", self.pidfile),
                  patch.object(host.sys, "platform", "darwin"),
                  patch.object(host.os, "getuid", return_value=501),
                  patch.object(Path, "read_text", return_value="101\n"),
                  patch.object(host.ctypes, "CDLL", return_value=libproc),
                  patch.object(host.subprocess, "check_output", side_effect=output),
                  patch.object(host.subprocess, "run", side_effect=clear)]:
            p.start()
            self.addCleanup(p.stop)

    def verify(self):
        output = io.StringIO()
        with redirect_stdout(output):
            host.qos()
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 2)
        for line, role, pid in zip(lines, ("ci-hostagent", "ci-virtualization-xpc"), (101, 202)):
            self.assertEqual(line, f"ci-vm: {role} pid={pid} background=false flags=0x0")

    def test_hostagent_state_proves_absence_or_retains_unknown(self):
        with patch.object(Path, "read_text", side_effect=FileNotFoundError):
            self.assertEqual(host.hostagent_state(), 0)
        with patch.object(host.os, "kill", side_effect=ProcessLookupError):
            self.assertEqual(host.hostagent_state(), 0)
        with patch.object(host.os, "kill", side_effect=PermissionError):
            self.assertEqual(host.hostagent_state(), 101)
        with patch.object(host.os, "kill"):
            self.assertEqual(host.hostagent_state(), 101)
            with patch.object(host, "hostagent", side_effect=RuntimeError("inspection failed")):
                with self.assertRaisesRegex(RuntimeError, "inspection failed"):
                    host.hostagent_state()
        with patch.object(Path, "read_text", return_value="bad"):
            with self.assertRaises(ValueError):
                host.hostagent_state()

    def test_reused_hostagent_pid_is_absent_but_inspection_errors_are_unknown(self):
        with patch.object(host.os, "kill"):
            self.executables[101] = "unrelated"
            self.assertEqual(host.hostagent_state(), 0)
            self.executables[101] = "limactl"
            self.args = "limactl hostagent --pidfile /other/ha.pid ci"
            self.assertEqual(host.hostagent_state(), 0)
            self.unreadable = 101
            with self.assertRaisesRegex(RuntimeError, "cannot inspect"):
                host.hostagent_state()

    def test_hostagent_identity_for_lock_handoff(self):
        self.assertEqual(host.hostagent()[0], 101)
        self.assertEqual(self.clears, [])

    def test_standard_pids_need_no_clear(self):
        self.verify()
        self.assertEqual(self.clears, [])

    def test_start_command_has_no_taskpolicy_wrapper(self):
        self.assertFalse(any(Path(arg).name == "taskpolicy" for arg in host.COMMANDS["start"]))

    def test_must_fail_start_command_with_bare_or_absolute_taskpolicy(self):
        for executable in ("taskpolicy", "/usr/sbin/taskpolicy"):
            with self.subTest(executable=executable), patch.dict(
                host.COMMANDS, {"start": (executable, "-b", *host.COMMANDS["start"])}
            ):
                with self.assertRaises(AssertionError):
                    self.test_start_command_has_no_taskpolicy_wrapper()

    def test_external_background_flag_is_cleared_once_on_either_pid(self):
        for pid in (101, 202):
            with self.subTest(pid=pid):
                self.clears.clear()
                self.flags[pid] = 0x10000
                self.verify()
                self.assertEqual(self.clears, [pid])

    def test_both_pids_external_flags_are_cleared(self):
        self.flags.update({101: 0x10000, 202: 0x10000})
        self.verify()
        self.assertEqual(self.clears, [101, 202])

    def test_inherited_background_fails_after_one_clear_attempt(self):
        for pid in (101, 202):
            for flag in (0x8000, 0x18000):
                with self.subTest(pid=pid, flag=flag):
                    self.flags.update({101: 0, 202: 0, pid: flag})
                    self.clears.clear()
                    with redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError) as error:
                        host.qos()
                    self.assertEqual(str(error.exception),
                                     f"inherited background policy (0x8000) on PID {pid}: "
                                     "restart ci from the new starter")
                    self.assertEqual(self.clears, [pid])
                    self.assertEqual(self.flags[pid], 0x8000)

    def test_must_fail_if_external_background_survives_clear(self):
        self.stuck = True
        for pid in (101, 202):
            with self.subTest(pid=pid):
                self.flags.update({101: 0, 202: 0, pid: 0x10000})
                self.clears.clear()
                with redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, f"background policy still set for PID {pid}"):
                    host.qos()
                self.assertEqual(self.clears, [pid])

    def test_must_fail_if_reverification_cannot_run(self):
        for pid in (101, 202):
            with self.subTest(pid=pid):
                self.unreadable = "after-clear"
                self.flags.update({101: 0, 202: 0, pid: 0x10000})
                with redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, f"cannot inspect PID {pid}"):
                    host.qos()

    def test_must_fail_if_clear_command_fails(self):
        self.flags[101] = 0x10000
        host.subprocess.run.side_effect = subprocess.CalledProcessError(1, "taskpolicy")
        with self.assertRaises(subprocess.CalledProcessError):
            host.qos()

    def test_must_fail_if_initial_inspection_cannot_run(self):
        self.unreadable = 101
        with self.assertRaisesRegex(RuntimeError, "cannot inspect PID 101"):
            host.qos()

    def test_foreign_hostagent_is_rejected_before_clearing(self):
        self.flags[101] = 0x10000
        for field, value in ((self.owners, 502), (self.executables, "other")):
            original = field[101]
            field[101] = value
            with self.assertRaisesRegex(RuntimeError, "wrong owner or executable"):
                host.qos()
            field[101] = original
        self.args = "limactl hostagent --pidfile /other/ha.pid ci"
        with self.assertRaisesRegex(RuntimeError, "this ci instance's hostagent"):
            host.qos()
        self.assertEqual(self.clears, [])

    def test_missing_or_ambiguous_disk_owner_is_rejected_before_clearing(self):
        self.flags.update({101: 0x10000, 202: 0x10000, 303: 0x10000})
        for disk in ("other-disk", "disk"):
            with self.subTest(disk=disk):
                self.disks[202 if disk == "other-disk" else 303] = disk
                if disk == "disk":
                    self.disks[202] = "diffdisk"
                with self.assertRaisesRegex(RuntimeError, "cannot uniquely associate"):
                    host.qos()
                self.assertEqual(self.clears, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
