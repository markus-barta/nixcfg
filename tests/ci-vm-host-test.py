#!/usr/bin/env python3
"""Offline Darwin policy checks against the real host helper, without host CLIs."""

from contextlib import redirect_stdout
import importlib.util
import io
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
                self.flags[pid] = 0
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

    def test_standard_pids_need_no_clear(self):
        self.verify()
        self.assertEqual(self.clears, [])

    def test_either_background_flag_is_cleared_once_on_either_pid(self):
        for pid in (101, 202):
            for flag in (0x8000, 0x10000, 0x18000):
                with self.subTest(pid=pid, flag=flag):
                    self.clears.clear()
                    self.flags[pid] = flag
                    self.verify()
                    self.assertEqual(self.clears, [pid])

    def test_both_pids_are_cleared(self):
        self.flags.update({101: 0x8000, 202: 0x10000})
        self.verify()
        self.assertEqual(self.clears, [101, 202])

    def test_must_fail_if_background_survives_clear(self):
        self.stuck = True
        for pid in (101, 202):
            for flag in (0x8000, 0x10000, 0x18000):
                with self.subTest(pid=pid, flag=flag):
                    self.flags.update({101: 0, 202: 0, pid: flag})
                    self.clears.clear()
                    with redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, f"background policy still set for PID {pid}"):
                        host.qos()
                    self.assertEqual(self.clears, [pid])

    def test_must_fail_if_reverification_cannot_run(self):
        for pid in (101, 202):
            with self.subTest(pid=pid):
                self.unreadable = "after-clear"
                self.flags.update({101: 0, 202: 0, pid: 0x8000})
                with redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, f"cannot inspect PID {pid}"):
                    host.qos()

    def test_must_fail_if_clear_command_fails(self):
        self.flags[101] = 0x8000
        host.subprocess.run.side_effect = subprocess.CalledProcessError(1, "taskpolicy")
        with self.assertRaises(subprocess.CalledProcessError):
            host.qos()

    def test_must_fail_if_initial_inspection_cannot_run(self):
        self.unreadable = 101
        with self.assertRaisesRegex(RuntimeError, "cannot inspect PID 101"):
            host.qos()

    def test_foreign_hostagent_is_rejected_before_clearing(self):
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
