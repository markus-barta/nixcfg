#!/usr/bin/env python3
"""NIX-583: value-free metadata checks; never open enrollment files."""

import json
import os
from pathlib import Path
import stat
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def physical(path, label):
    require(path.is_absolute() and str(path.resolve()) == str(path),
            f"{label} must be a physical absolute path")


def private_file(path, label, maximum):
    physical(path, label)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_uid == os.getuid() and info.st_nlink == 1
            and 0 < info.st_size <= maximum,
            f"{label} must be a bounded owner-owned regular mode-0600 file with one link")


def directory(path, label):
    physical(path, label)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
            and info.st_uid == os.getuid(), f"{label} must be owner-owned mode 0700")


def preflight(config, prepare=False):
    home = Path(config["home"])
    key = Path(config["agentKeyFile"])
    accounts = Path(config["accountsFile"])
    workspace = Path(config["workspace"])
    state = Path(config["stateRoot"])
    require(state == home / "Library/Caches/aeon/agentd", "unexpected Aeon state root")
    classic = [home / "Library/Caches/paimos", home / "Library/Application Support/paimos"]
    for path in (key, accounts, workspace, state):
        physical(path, "configured path")
        require(home in path.parents and not any(p == path or p in path.parents for p in classic),
                "configured path overlaps classic or escapes home")
    require(key != accounts, "key and registry must be distinct")
    private_file(key, "agent key", 4096)
    private_file(accounts, "account registry", 65536)
    directory(key.parent, "key directory")
    directory(accounts.parent, "registry directory")
    require(workspace.is_dir(), "workspace must exist")
    if state.exists():
        directory(state, "state root")
    logs = [state / name for name in ("stdout.log", "stderr.log")]
    for log in logs:
        if log.exists() or log.is_symlink():
            physical(log, "log")
            info = log.lstat()
            require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
                    and info.st_uid == os.getuid() and info.st_nlink == 1,
                    "existing log must be owner-owned regular mode 0600 with one link")
    if prepare:
        old_umask = os.umask(0o077)
        try:
            state.mkdir(mode=0o700, parents=True, exist_ok=True)
            directory(state, "state root")
            for log in logs:
                if not log.exists():
                    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    os.close(fd)
        finally:
            os.umask(old_umask)


def main(config):
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ("check", "prepare"), "invalid preflight invocation")
        # Nix embeds path metadata in this script; no configuration-file reads.
        preflight(config, prepare=sys.argv[1] == "prepare")
    except (ValueError, OSError):
        # Do not echo paths, JSON, registry contents, or exception payloads.
        print("aeon-agentd: enrollment/state metadata preflight failed; review NIX-583 requirements", file=sys.stderr)
        sys.exit(1)
