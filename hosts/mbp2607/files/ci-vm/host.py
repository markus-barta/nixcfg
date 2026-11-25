#!/usr/bin/env python3
"""Host-only locking and narrowly scoped Darwin background-policy enforcement."""

import ctypes
import fcntl
import math
import os
from pathlib import Path
import signal
import shlex
import struct
import subprocess
import sys


# Rendered by ci-vm.nix, rather than selected by argv or the environment.
STATE_DIR = "@stateDir@"
PIDFILE = "@pidfile@"
DISPATCHER = "@dispatcher@"
QOS_COMMAND = (sys.executable, __file__, "qos", PIDFILE)
COMMANDS = {
    "status": ("colima", "status", "ci", "--json"),
    "stop": ("colima", "stop", "ci"),
    "start": ("taskpolicy", "-b", "-c", "background", "colima", "start", "ci",
              "--activate=false", "--ssh-config=false"),
    "qos": QOS_COMMAND,
    "host-ready": ("colima", "--profile", "ci", "ssh", "--", "sudo",
                   "/usr/local/libexec/ci-vm/host-ready"),
    "provision-only": ("colima", "--profile", "ci", "ssh", "--", "sudo",
                       "/usr/local/libexec/ci-vm/host-ready", "--provision-only"),
    "worker-active": ("colima", "--profile", "ci", "ssh", "--", "sudo",
                      "/usr/local/libexec/ci-vm/control", "worker-active"),
    "enrolled": ("colima", "--profile", "ci", "ssh", "--", "sudo",
                 "/usr/local/libexec/ci-vm/control", "enrolled"),
    "drain": ("colima", "--profile", "ci", "ssh", "--", "sudo",
              "/usr/local/libexec/ci-vm/control", "drain"),
}
LOCK_COMMANDS = {
    ("/bin/bash", DISPATCHER, "--locked", *arguments):
        ("/bin/bash", DISPATCHER, "--locked", *arguments)
    for arguments in ((), ("tick",), ("prepare",), ("start",),
                      ("start", "--provision-only"), ("stop",), ("stop", "--force"))
}


def bounded(seconds, command):
    """Bound our CLI process group, including SSH children, without a shell."""
    with subprocess.Popen(command, start_new_session=True) as proc:
        try:
            return proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            print(f"ci-vm: command timed out after {seconds}s: {command[0]}", file=sys.stderr)
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            # A CLI can exit on TERM while a child ignores it and holds pipes
            # open. Kill remaining members even when the leader already exited.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            return 124


def lock(path, command):
    # Keep the lock in this parent, with close_fds in the child. Lima's detached
    # daemons must never inherit it and keep future dispatcher polls locked out.
    # There is no stale mkdir/PID lock after a crash or reboot.
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("ci-vm: another dispatcher invocation holds the lock")
        os.close(fd)
        return 0
    try:
        return subprocess.call(command, close_fds=True)
    finally:
        os.close(fd)


def qos():
    if sys.platform != "darwin":
        raise RuntimeError("QoS enforcement requires Darwin")
    pidfile = Path(PIDFILE)
    pid = int(pidfile.read_text().strip())
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidinfo.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int
    ]
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]

    def info(target):
        # PROC_PIDTBSDINFO; flags, status, xstatus, pid, ppid, uid.
        buf = ctypes.create_string_buffer(136)
        if libproc.proc_pidinfo(target, 3, 0, buf, len(buf)) != len(buf):
            raise RuntimeError(f"cannot inspect PID {target}")
        return struct.unpack_from("6I", buf.raw)

    def executable(target):
        buf = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(target, buf, len(buf)) <= 0:
            raise RuntimeError(f"cannot identify PID {target}")
        return Path(os.fsdecode(buf.value)).name

    if info(pid)[5] != os.getuid() or executable(pid) not in {"limactl", ".limactl-wrapped"}:
        raise RuntimeError("ci hostagent PID has the wrong owner or executable")
    args = shlex.split(subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", "command="], text=True
    ))
    if "hostagent" not in args or not any(str(pidfile) in arg for arg in args):
        raise RuntimeError("PID does not identify this ci instance's hostagent")

    targets = [(pid, "ci-hostagent")]
    # A responsibility PID can be shared by several VMs launched from one
    # terminal. Instead use this hostagent's launchd domain AND its open disk.
    domain = subprocess.check_output(
        ["/bin/launchctl", "print", f"pid/{pid}"], text=True
    )
    for row in domain.splitlines():
        fields = row.split()
        if (
            len(fields) != 3
            or not fields[0].isdigit()
            or not fields[2].startswith("com.apple.Virtualization.VirtualMachine.")
        ):
            continue
        candidate = int(fields[0])
        if (
            candidate == 0
            or info(candidate)[5] != os.getuid()
            or executable(candidate) != "com.apple.Virtualization.VirtualMachine"
        ):
            continue
        files = subprocess.check_output(
            # -b avoids potentially blocking stat/readlink on unrelated mounted
            # filesystems; -w suppresses those skipped-filesystem warnings.
            ["/usr/sbin/lsof", "-n", "-P", "-b", "-w", "-a", "-p", str(candidate), "-Fn"], text=True
        ).splitlines()
        if any("n" + str(pidfile.parent / disk) in files for disk in ("disk", "diffdisk")):
            targets.append((candidate, "ci-virtualization-xpc"))
    if len(targets) != 2:
        raise RuntimeError("cannot uniquely associate a Virtualization XPC process with ci's disk")

    for target, role in targets:
        subprocess.run(["/usr/sbin/taskpolicy", "-b", "-p", str(target)], check=True)
        # SDK mach/task_policy.h: PROC_FLAG_DARWINBG / EXT_DARWINBG.
        flags = info(target)[0]
        if not flags & (0x8000 | 0x10000):
            raise RuntimeError(f"background policy absent for PID {target}")
        print(f"ci-vm: {role} pid={target} background=true flags={flags:#x}")


if __name__ == "__main__":
    try:
        if len(sys.argv) >= 6 and sys.argv[1] == "lock":
            lockfile = str(Path(STATE_DIR) / "dispatcher.lock")
            if sys.argv[2] != lockfile:
                raise RuntimeError("unexpected dispatcher lock path")
            sys.exit(lock(lockfile, LOCK_COMMANDS[tuple(sys.argv[3:])]))
        elif len(sys.argv) == 3 and sys.argv[1] == "qos":
            if sys.argv[2] != PIDFILE:
                raise RuntimeError("unexpected ci hostagent PID path")
            qos()
        elif len(sys.argv) == 4 and sys.argv[1] == "run":
            seconds = float(sys.argv[2])
            if not math.isfinite(seconds) or not 0 < seconds <= 900:
                raise RuntimeError("invalid ci command deadline")
            sys.exit(bounded(seconds, COMMANDS[sys.argv[3]]))
        else:
            raise RuntimeError("unknown ci-vm host operation")
    except KeyError:
        print("ci-vm: unsupported dispatcher command", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ci-vm: {exc}", file=sys.stderr)
        sys.exit(1)
