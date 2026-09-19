#!/usr/bin/env python3
"""NIX-524: stage npm updates, verify, then atomically publish each CLI link.

Never installs into the live prefix. Legacy packages and previous generations
stay in place for running processes and rollback. The bin links are the source
of truth for installed versions, including after an interrupted publication.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import uuid


class UpdateError(Exception):
    pass


def read_json(path):
    return json.loads(path.read_text())


def real_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise UpdateError(f"expected a real directory: {path}")
    path.mkdir(parents=True, exist_ok=True)


def link_value(path):
    if path.is_symlink():
        return os.readlink(path)
    if path.exists():
        raise UpdateError(f"refusing to replace a non-symlink: {path}")
    return None


def checked_link(path, target, previous):
    if link_value(path) != previous:
        raise UpdateError(f"launch link changed during update: {path}")
    temporary = path.with_name(f".{path.name}-{uuid.uuid4().hex}")
    temporary.symlink_to(target)
    # rename replaces the directory entry, never the old link's target.
    os.replace(temporary, path)


def run(args, *, extra_env=None, timeout=60, cwd=None):
    process_env = dict(os.environ)
    process_env.update(extra_env or {})
    try:
        result = subprocess.run(args, env=process_env, capture_output=True,
                                text=True, timeout=timeout, check=False, cwd=cwd)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UpdateError(f"{Path(args[0]).name} could not complete ({type(exc).__name__})") from exc
    if result.returncode:
        # Vendor output can contain local configuration. Do not echo it.
        raise UpdateError(f"{Path(args[0]).name} failed (exit {result.returncode})")
    return result.stdout


def package_at_link(link, name, prefix):
    try:
        boundary = prefix.resolve()
        executable = link.resolve(strict=False)
        executable.relative_to(boundary)
        for parent in executable.parents:
            if parent == boundary:
                break
            metadata = parent / "package.json"
            if metadata.is_file():
                data = read_json(metadata)
                if data.get("name") == name:
                    return data
    except (OSError, ValueError):
        pass
    return None


def verify(binary, version):
    # Command names are fixed; a custom prefix selects the working directory,
    # never an arbitrary executable from a command-line argument.
    commands = {"claude": "./claude", "codex": "./codex", "grok": "./grok",
                "pi": "./pi", "bird": "./bird"}
    output = run([commands[binary.name], "--version"], cwd=binary.parent, extra_env={
        "DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1",
    }, timeout=30)
    if not re.search(r"(?<![\w.])" + re.escape(version) + r"(?![\w.])", output):
        raise UpdateError(f"{binary.name} did not report expected version {version}")


def supports(values, actual):
    if not values:
        return True
    positive = [v for v in values if not v.startswith("!")]
    return f"!{actual}" not in values and (not positive or actual in positive or "any" in positive)


def resolve_package(package):
    spec = f"{package['name']}@{package['version']}"
    data = json.loads(run(["npm", "view", spec, "version", "os", "cpu", "--json"]))
    if isinstance(data, str):
        data = {"version": data}
    version = data.get("version", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version):
        raise UpdateError(f"registry returned no exact version for {spec}")
    if package["version"] != "latest" and version != package["version"]:
        raise UpdateError(f"registry did not return the exact pin for {spec}")
    system = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), "unsupported")
    arch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x64",
            "armv6l": "arm", "armv7l": "arm"}.get(platform.machine(), platform.machine())
    if not supports(data.get("os"), system) or not supports(data.get("cpu"), arch):
        print(f"ai-clis: {package['name']} unsupported on {system}/{arch}; existing install kept")
        return None
    return version


def rollback(receipt, prefix):
    data = read_json(receipt)
    if data.get("prefix") != str(prefix) or data.get("schema") != 1:
        raise UpdateError("rollback receipt does not match this prefix")
    records = data["updates"]
    for item in records:
        if not re.fullmatch(r"[a-z][a-z0-9-]*", item["bin"]):
            raise UpdateError("invalid rollback command")
        link = prefix / "bin" / item["bin"]
        if item["previous"] is None:
            raise UpdateError("cannot roll back a first installation; no prior CLI exists")
        old = (link.parent / item["previous"]).resolve(strict=True)
        old.relative_to(prefix.resolve())
        if link_value(link) not in (item["previous"], item["target"]):
            raise UpdateError(f"{item['bin']} changed since this update; rollback refused")
        if not os.access(old, os.X_OK):
            raise UpdateError(f"old {item['bin']} is not executable")
    for item in records:
        link = prefix / "bin" / item["bin"]
        if link_value(link) == item["target"]:
            checked_link(link, item["previous"], item["target"])
            print(f"ai-clis: restored {item['bin']}")


def update(args, prefix, state):
    packages = read_json(args.packages)
    approvals = read_json(args.allow_scripts)["allowScripts"]
    changes = []
    for package in packages:
        name, binary = package["name"], package["bin"]
        if not re.fullmatch(r"(?:@[a-z0-9-]+/)?[a-z0-9-]+", name) or not re.fullmatch(r"[a-z][a-z0-9-]*", binary):
            raise UpdateError("invalid package declaration")
        link = prefix / "bin" / binary
        previous = link_value(link)
        installed = package_at_link(link, name, prefix)
        if previous is not None and installed is None:
            raise UpdateError(f"{binary} does not point to the declared package; preserved")
        version = resolve_package(package)
        if version is None:
            continue
        if installed and installed.get("version") == version:
            try:
                verify(link, version)
                print(f"ai-clis: {binary} {version} current; no reinstall")
                continue
            except UpdateError:
                print(f"ai-clis: {binary} {version} needs repair; staging replacement")
        changes.append({"name": name, "bin": binary, "version": version, "previous": previous})
    if args.check:
        print(f"ai-clis: {len(changes)} package(s) need staging; check only")
        return
    if not changes:
        print("ai-clis: all versions current; no installation or launch-link changes")
        return
    for item in changes:
        stage = Path(tempfile.mkdtemp(prefix="package-", dir=state))
        print(f"ai-clis: staging {item['bin']} {item['version']} in {stage}", flush=True)
        # Grok's approved postinstall also writes to GROK_HOME. Keep that work
        # private until the package-local native executable passes validation.
        install_env = {"NPM_CONFIG_PREFIX": str(stage), "GROK_HOME": str(stage / "grok-home")}
        run(["npm", "install", "--global", "--prefix", str(stage),
             f"--allow-scripts={','.join(approvals)}", "--no-audit", "--no-fund",
             f"{item['name']}@{item['version']}"], extra_env=install_env, timeout=600)
        target = stage / "bin" / item["bin"]
        metadata = package_at_link(target, item["name"], stage)
        if not metadata or metadata.get("version") != item["version"]:
            raise UpdateError(f"staged {item['bin']} package identity/version mismatch")
        verify(target, item["version"])
        item["target"] = str(target)
    # Prepare rollback evidence before publishing anything. A signal/failure
    # may publish a subset, but every link always resolves to a verified CLI.
    receipt = state / f"update-{uuid.uuid4().hex}.json"
    receipt.write_text(json.dumps({"schema": 1, "prefix": str(prefix), "updates": changes}, indent=2) + "\n")
    print(f"ai-clis: rollback receipt {receipt}", flush=True)
    for item in changes:
        if link_value(prefix / "bin" / item["bin"]) != item["previous"]:
            raise UpdateError(f"{item['bin']} changed during staging; publication refused")
    for item in changes:
        checked_link(prefix / "bin" / item["bin"], item["target"], item["previous"])
        print(f"ai-clis: published {item['bin']} {item['version']}", flush=True)


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".npm-global")
    parser.add_argument("--packages", type=Path, default=root / "modules/uzumaki/ai-clis-npm-packages.json")
    parser.add_argument("--allow-scripts", type=Path, default=root / "modules/uzumaki/ai-clis-npm-allow-scripts.json")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="resolve versions and report without installing")
    modes.add_argument("--rollback", type=Path, help="restore links recorded by this updater, without npm")
    args = parser.parse_args()
    prefix = args.prefix.absolute()
    old_umask = os.umask(0o022)
    try:
        if args.check:
            update(args, prefix, None)
            return 0
        real_directory(prefix)
        real_directory(prefix / "bin")
        state = prefix / ".ai-cli-updates"
        real_directory(state)
        lock_path = state / "lock"
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise UpdateError("another CLI update owns the lock; no install started") from exc
            if args.rollback:
                rollback(args.rollback, prefix)
            else:
                update(args, prefix, state)
        return 0
    except (UpdateError, OSError, ValueError, KeyError) as exc:
        print(f"ai-clis: {exc}; prior package files retained", file=sys.stderr)
        return 1
    finally:
        os.umask(old_umask)


if __name__ == "__main__":
    sys.exit(main())
