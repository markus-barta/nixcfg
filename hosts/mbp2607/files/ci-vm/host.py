#!/usr/bin/env python3
"""Host-only locking and narrowly scoped Darwin background-policy enforcement."""

import ctypes
import fcntl
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys


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


def qos(pidfile):
    if sys.platform != "darwin":
        raise RuntimeError("QoS enforcement requires Darwin")
    pidfile = Path(pidfile)
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
        if sys.argv[1] == "lock":
            sys.exit(lock(sys.argv[2], sys.argv[3:]))
        elif sys.argv[1] == "qos":
            qos(sys.argv[2])
        else:
            raise RuntimeError("unknown ci-vm host operation")
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ci-vm: {exc}", file=sys.stderr)
        sys.exit(1)
