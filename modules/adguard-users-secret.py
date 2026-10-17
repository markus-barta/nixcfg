#!/usr/bin/env python3
"""Merge runtime-only AdGuard users; never emit input or parser diagnostics."""

import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

LOCKED_MESSAGE = "AdGuard admin locked; DNS/DHCP remain enabled (OPS-372)."


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def read_users(secret_path):
    # JSON is a YAML subset. Read the secret here, never in Nix evaluation,
    # shell substitutions, argv, environment, or a diagnostic message.
    with open(secret_path, encoding="utf-8") as handle:
        users = json.load(handle, object_pairs_hook=unique_object)
    bcrypt = re.compile(r"\$2[aby]\$(?:0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}")
    if not isinstance(users, list) or not users:
        raise ValueError("nonempty users required")
    names = set()
    for user in users:
        if not isinstance(user, dict) or set(user) != {"name", "password"}:
            raise ValueError("invalid user fields")
        name, verifier = user["name"], user["password"]
        if not isinstance(name, str) or not name.strip() or name in names:
            raise ValueError("invalid or duplicate name")
        if not isinstance(verifier, str) or not bcrypt.fullmatch(verifier):
            raise ValueError("invalid verifier")
        names.add(name)
    return users


def inject(config_path, secret_path, yq, marker_path, port):
    locked = False
    try:
        users = read_users(secret_path)
    except Exception:
        # Never allow an empty users list (AdGuard treats it as no auth).
        # The random password exists only in memory and cannot be recovered.
        import bcrypt
        users = [{"name": "admin", "password": bcrypt.hashpw(os.urandom(32).hex().encode(), bcrypt.gensalt(rounds=12)).decode()}]
        locked = True

    target = Path(config_path)
    metadata = target.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("expected a regular runtime config")
    parsed = subprocess.run(
        [yq, "eval", "-o=json", ".", str(target)],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    settings = json.loads(parsed.stdout)
    if not isinstance(settings, dict):
        raise ValueError("invalid config")
    settings["users"] = users
    if locked:
        if not isinstance(settings.get("http"), dict):
            raise ValueError("missing HTTP settings")
        settings["http"]["address"] = f"127.0.0.1:{int(port)}"

    marker = Path(marker_path)
    if locked:
        # Publish health failure before changing config. Marker write failures
        # are fatal, as are config/parser failures below.
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write("admin locked\n")
        marker.chmod(0o600)

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".adguard-users-", delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            # This runs as the same DynamicUser as nixpkgs' preceding copy;
            # no privileged chown or sandbox exceptions are necessary.
            temporary_metadata = os.fstat(handle.fileno())
            if (temporary_metadata.st_uid, temporary_metadata.st_gid) != (metadata.st_uid, metadata.st_gid):
                raise ValueError("runtime ownership mismatch")
            subprocess.run(
                [yq, "eval", "-P", "-p=json", "-o=yaml", ".", "-"],
                input=json.dumps(settings).encode(), stdout=handle,
                stderr=subprocess.DEVNULL, check=True,
            )
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    if locked:
        print(LOCKED_MESSAGE, file=sys.stderr)
    else:
        marker.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        os.umask(0o077)
        inject(*sys.argv[1:])
    except Exception:
        # Deliberately suppress tracebacks, YAML, usernames and verifier values.
        sys.exit("AdGuard users injection failed; refusing to start (OPS-372).")
