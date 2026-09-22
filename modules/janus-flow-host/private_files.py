#!/usr/bin/env python3
"""Publish Janus mount targets without logging or exposing credential bytes."""

import argparse
import os
import stat
import sys
import tempfile
from pathlib import Path


SOURCE = Path("/run/agenix/csb1-janus-flow-api-key")
CREDENTIAL = Path("/run/janus-flow-credential/api-key")
PLACEHOLDER = Path("/run/janus/flow-host/api-key")
DIRECTORIES = (CREDENTIAL.parent, PLACEHOLDER.parent, PLACEHOLDER.parent.parent)


class FixtureScope:
    """An explicitly created, private synthetic root; never a caller-picked path."""

    def __init__(self):
        self._temporary = tempfile.TemporaryDirectory(prefix="janus-flow-fixture-")
        self.root = Path(self._temporary.name).resolve()
        info = self.root.lstat()
        self._identity = (info.st_dev, info.st_ino, info.st_uid, info.st_gid)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self._temporary.cleanup()

    def admit(self, path):
        info = self.root.lstat()
        if (info.st_dev, info.st_ino, info.st_uid, info.st_gid) != self._identity or not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("synthetic root changed")
        path = Path(path)
        if not path.is_absolute() or ".." in path.parts or not path.is_relative_to(self.root):
            raise ValueError("path outside synthetic root")
        # Reject every ancestor, not only the immediate parent. The private root
        # excludes other users; the leaf checks below also retain O_NOFOLLOW.
        current = self.root
        for part in path.relative_to(self.root).parts:
            current = current / part
            try:
                if stat.S_ISLNK(current.lstat().st_mode):
                    raise ValueError("synthetic path is a symlink")
            except FileNotFoundError:
                break
        return path


def admitted(path, choices, fixture):
    if fixture is not None:
        if not isinstance(fixture, FixtureScope):
            raise ValueError("invalid synthetic scope")
        return fixture.admit(path)
    # Return the trusted constant, never the supplied pathname. Production
    # activation has exactly these paths; arbitrary root CLI paths are refused.
    for known in choices:
        if str(path) == str(known):
            return known
    raise ValueError("path outside Janus Flow publication contract")


def private_directory(path, uid, gid, *, fixture=None):
    path = admitted(path, DIRECTORIES, fixture)
    if path.parent.is_symlink():
        raise ValueError("private directory parent is a symlink")
    if not path.parent.exists():
        private_directory(path.parent, os.geteuid(), os.getegid(), fixture=fixture)
    try:
        path.mkdir(mode=0o700)
        os.chown(path, uid, gid)
    except FileExistsError:
        pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, 0o700):
        raise ValueError("private directory metadata")


def checked_file(path, uid, gid, *, empty=False, fixture=None):
    path = admitted(path, (SOURCE, CREDENTIAL, PLACEHOLDER), fixture)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError("private file type")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError("file changed while opening")
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("private file type")
        if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, 0o400):
            raise ValueError("private file metadata")
        if empty:
            if info.st_size != 0:
                raise ValueError("mount target is not empty")
            return b""
        if not 32 <= info.st_size <= 512:
            raise ValueError("credential size")
        data = os.read(fd, 513)
        if len(data) != info.st_size or any(byte < 0x21 or byte > 0x7e for byte in data):
            raise ValueError("credential format")
        return data
    finally:
        os.close(fd)


def placeholder(path, uid, gid, *, fixture=None):
    path = admitted(path, (PLACEHOLDER,), fixture)
    private_directory(path.parent, uid, gid, fixture=fixture)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        checked_file(path, uid, gid, empty=True, fixture=fixture)
        return
    try:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o400)
        os.fsync(fd)
    finally:
        os.close(fd)
    checked_file(path, uid, gid, empty=True, fixture=fixture)


def credential(source, destination, uid, gid, *, fixture=None):
    """Leave the mounted inode alone when agenix republishes identical bytes."""
    source = admitted(source, (SOURCE,), fixture)
    destination = admitted(destination, (CREDENTIAL,), fixture)
    # The CLI runs as root; tests use a private fixture owned by their caller.
    owner, group = os.geteuid(), os.getegid()
    data = checked_file(source, owner, group, fixture=fixture)
    private_directory(destination.parent, owner, group, fixture=fixture)
    try:
        previous = checked_file(destination, uid, gid, fixture=fixture)
    except FileNotFoundError:
        previous = None
    if previous == data:
        return False
    fd, temporary = tempfile.mkstemp(prefix=".api-key-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchown(stream.fileno(), uid, gid)
            os.fchmod(stream.fileno(), 0o400)
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        parent_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("placeholder", "credential"))
    parser.add_argument("destination")
    parser.add_argument("--source")
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0 or args.uid < 0 or args.gid < 0:
        parser.error("requires root and numeric ownership")
    if args.operation == "credential" and not args.source:
        parser.error("credential requires source")
    os.umask(0o077)
    try:
        if args.operation == "placeholder":
            if args.destination != str(PLACEHOLDER) or args.source is not None:
                raise ValueError("placeholder path contract")
            placeholder(PLACEHOLDER, args.uid, args.gid)
        else:
            if args.source != str(SOURCE) or args.destination != str(CREDENTIAL):
                raise ValueError("credential path contract")
            credential(SOURCE, CREDENTIAL, args.uid, args.gid)
    except (OSError, ValueError):
        # No exception text, paths, or bytes enter the journal.
        print("Janus Flow private-file publication refused", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
