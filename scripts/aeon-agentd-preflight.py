#!/usr/bin/env python3
"""NIX-583 / NIX-589: value-free metadata checks; never open enrollment or pairing files."""

import json
import os
from pathlib import Path
import stat
import sys


class PreflightError(ValueError):
    """Only static, value-free messages may cross this diagnostic boundary."""


def require(condition, message):
    if not condition:
        raise PreflightError(message)


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
    require(state == home / "Library/Application Support/aeon/agentd/state", "unexpected Aeon state root")
    classic = [home / "Library/Caches/paimos", home / "Library/Application Support/paimos"]
    for path in (key, accounts, workspace, state):
        physical(path, "configured path")
        require(home in path.parents and not any(p == path or p in path.parents for p in classic),
                "configured path overlaps classic or escapes home")
    require(key != accounts, "key and registry must be distinct")
    require(not any(workspace == p or workspace in p.parents for p in (key, accounts, state)),
            "workspace must not contain enrollment files or daemon state")
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


# NIX-589: exactly the files `aeon-agentd serve --setup-root` reads through
# agentsetup.Store.Read before it runs (Aeon 6b5e5e7c, unchanged in 6003e954),
# with that function's byte bounds: the approval snapshot, the runtime
# configuration and the runtime credential. Metadata only; never opened.
PAIRED_FILES = {
    "pairing.json": 1 << 20,   # Engine.load: snapshotName
    "runtime.json": 128 << 10,  # ReadRuntimeConfig: RuntimeName
    "runtime.key": 4096,        # ReadRuntime
}


def walk(path, label, create=False, allow_missing=False):
    """Open `path` component by component from / without following symlinks.

    Mirrors agentsetup.openDirectory: every component is owned by the user or
    root and is not group/other writable (a root-owned sticky directory is
    allowed), and the final directory is owned by the user with mode 0700.
    Missing components are created with mode 0700 relative to their parent's
    file descriptor when `create` is set. Returns the final directory's fd, or
    None when it is missing and `allow_missing` is set.
    """
    text = str(path)
    require(path.is_absolute() and os.path.normpath(text) == text and text != "/",
            f"{label} must be a physical absolute path")
    parts = text.strip("/").split("/")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(parts):
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            try:
                nxt = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    if allow_missing:
                        os.close(fd)
                        fd = -1
                        return None
                    raise
                os.mkdir(part, 0o700, dir_fd=fd)
                nxt = os.open(part, flags, dir_fd=fd)
            except OSError:
                raise PreflightError(f"{label} and its ancestors must be real directories, not symlinks")
            os.close(fd)
            fd = nxt
            info = os.fstat(fd)
            owned = info.st_uid == os.getuid()
            trusted = (owned or info.st_uid == 0) and (
                stat.S_IMODE(info.st_mode) & 0o022 == 0
                or info.st_uid == 0 and info.st_mode & stat.S_ISVTX)
            require(trusted, f"{label}: every ancestor must be owned by you or root and not writable by others")
            if index == len(parts) - 1:
                require(owned and stat.S_IMODE(info.st_mode) == 0o700,
                        f"{label} must be owned by you with mode 0700")
        result, fd = fd, -1
        return result
    finally:
        if fd >= 0:
            os.close(fd)


def private_entry(dir_fd, name, label, maximum=None):
    info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_uid == os.getuid() and info.st_nlink == 1
            and (maximum is None or 0 < info.st_size <= maximum),
            f"{label} must be an owner-owned regular mode-0600 file with one link"
            + ("" if maximum is None else f" and 1..{maximum} bytes"))


def paired_preflight(config, prepare=False):
    """NIX-589: the paired runtime starts only from an approved pairing root.

    Setup writes runtime.json and runtime.key only after the person approves
    the computer in Aeon. Whether that approval is still valid (revocation,
    fences) lives in the file contents, which this metadata gate never reads;
    the daemon itself refuses a revoked pairing and exits cleanly.
    """
    home = Path(config["home"])
    root = Path(config["pairedRoot"])
    logs = Path(config["logRoot"])
    hint = config["pairHint"]
    workspace = Path(config["workspace"]) if config.get("workspace") else None
    managed = [Path(p) for p in config["managedPaths"]]
    classic = [home / "Library/Caches/paimos", home / "Library/Application Support/paimos"]
    for path in (root, logs):
        physical(path, "paired path")
        require(home in path.parents and not str(path).startswith("/nix/store/"),
                "paired path must be inside home and outside the Nix store")
        require(not any(p == path or p in path.parents or path in p.parents for p in managed + classic),
                "paired path overlaps the explicit-key daemon or classic state")
        require(workspace is None or not (workspace == path or workspace in path.parents
                                          or path in workspace.parents),
                "paired path must be outside the approved workspace")
    try:
        root_fd = walk(root, "pairing root")
    except FileNotFoundError:
        raise PreflightError(f"no approved pairing yet: {hint}")
    try:
        for name, maximum in PAIRED_FILES.items():
            try:
                private_entry(root_fd, name, f"pairing file {name}", maximum)
            except FileNotFoundError:
                raise PreflightError(f"pairing is not approved yet ({name} missing): {hint}")
        try:
            info = os.stat("daemon", dir_fd=root_fd, follow_symlinks=False)
            require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
                    and info.st_uid == os.getuid(), "paired daemon state must be owner-owned mode 0700")
        except FileNotFoundError:
            pass
    finally:
        os.close(root_fd)
    log_fd = walk(logs, "paired log root", create=prepare, allow_missing=not prepare)
    if log_fd is None:
        return
    try:
        for name in ("stdout.log", "stderr.log"):
            try:
                private_entry(log_fd, name, f"log {name}")
            except FileNotFoundError:
                if prepare:
                    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                                 dir_fd=log_fd)
                    os.close(fd)
    finally:
        os.close(log_fd)


def main(config):
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ("check", "prepare"), "invalid preflight invocation")
        # Nix embeds path metadata in this script; no configuration-file reads.
        run = paired_preflight if config.get("mode") == "paired" else preflight
        run(config, prepare=sys.argv[1] == "prepare")
    except PreflightError as error:
        print(f"aeon-agentd: {error}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, RuntimeError):
        # Do not echo paths, JSON, registry contents, or exception payloads.
        print("aeon-agentd: enrollment/state metadata preflight failed; review NIX-583 requirements", file=sys.stderr)
        sys.exit(1)
