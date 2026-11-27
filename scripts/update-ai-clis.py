#!/usr/bin/env python3
"""NIX-524: stage npm updates, verify, then atomically publish each CLI link.

Never installs into the live prefix. Keep each live generation, at most one
previous generation per CLI for rollback, and generations in use by processes.
Legacy prefix packages are never pruned. The bin links are the source of truth
for installed versions, including after an interrupted publication.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import shutil
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
                if (isinstance(data, dict) and isinstance(data.get("name"), str)
                        and re.fullmatch(r"(?:@[a-z0-9-]+/)?[a-z0-9-]+", data["name"])
                        and (name is None or data["name"] == name)):
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


def generations_in_use(state):
    # An independently running child must also be visible, with an inherited
    # lock descriptor. Always reap it, including on failed or timed-out scans.
    with (state / "lock").open("rb") as descriptor:
        child = subprocess.Popen(["sleep", "60"], pass_fds=(descriptor.fileno(),),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            return lsof_paths(state, child.pid)
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def lsof_paths(state, child_pid):
    # Fixed command name, one recursive scan. macOS can exit 1 for unrelated
    # mount warnings even with -w. Trust only a scan that sees our open lock.
    lock_path = (state / "lock").resolve()
    result = subprocess.run(["lsof", "-w", "-nP", "-F0pfn", "+D", str(state)],
                            capture_output=True, text=True, timeout=60, check=False)
    if result.returncode not in (0, 1) or result.stderr:
        raise UpdateError("lsof scan failed or was incomplete")
    paths_by_pid = {}
    process = None
    self_canary = False
    child_canary = False
    process_has_file = False
    file_pending = False
    if not result.stdout or not result.stdout.endswith("\0\n"):
        raise UpdateError("unparsable lsof output")
    for field in result.stdout.split("\0"):
        field = field.removeprefix("\n")
        if not field:
            continue
        tag, value = field[0], field[1:]
        if tag == "p" and value.isascii() and value.isdigit() and not file_pending:
            if process and not process_has_file:
                raise UpdateError("incomplete lsof process record")
            process = int(value)
            process_has_file = False
        elif tag == "f" and process and value and not file_pending:
            file_pending = True
        elif tag == "n" and file_pending and value.startswith("/") and "\n" not in value:
            # lsof escapes unusual filename bytes; do not guess their meaning.
            if "\\" in value or "^" in value:
                raise UpdateError("unparsable lsof path")
            path = Path(value)
            if not path.resolve().is_relative_to(state.resolve()):
                raise UpdateError("lsof path outside state directory")
            paths_by_pid.setdefault(process, []).append(path)
            if process == os.getpid() and path.resolve() == lock_path:
                self_canary = True
            if process == child_pid and path.resolve() == lock_path:
                child_canary = True
            file_pending = False
            process_has_file = True
        else:
            raise UpdateError("unparsable lsof output")
    if file_pending or not process_has_file:
        raise UpdateError("incomplete lsof output")
    if not self_canary:
        raise UpdateError("lsof scan missing this process's open-lock canary")
    if not child_canary:
        raise UpdateError("lsof scan missing child's open-lock canary")
    return paths_by_pid


def generation_for(path, state):
    """Map a resolved path to a direct state child, never to a sibling prefix."""
    try:
        relative = path.resolve().relative_to(state)
    except ValueError:
        return None
    return state / relative.parts[0] if relative.parts else None


def process_generations(prefix, state, paths_by_pid):
    """Hold a link-started CLI only when that PID has no lsof state paths."""
    # HM activation omits system directories from PATH. Linux's wrapper supplies
    # procps; Darwin uses the fixed system command, never a prefix-selected one.
    ps_command = "/bin/ps" if sys.platform == "darwin" else "ps"
    result = subprocess.run([ps_command, "-axww", "-o", "pid=,args="],
                            capture_output=True, text=True, errors="surrogateescape",
                            timeout=60, check=False)
    if result.returncode or result.stderr:
        raise UpdateError("ps scan failed or was incomplete")
    links = [link for link in (prefix / "bin").iterdir()
             if link.is_symlink() and generation_for(link, state) is not None]
    kept, held = set(), {}
    ps_canary = False
    seen = set()
    state_roots = {str(state), str(state.resolve()), str(prefix / state.name)}
    if not result.stdout or not result.stdout.endswith("\n"):
        raise UpdateError("unparsable ps output")
    for line in result.stdout.removesuffix("\n").split("\n"):
        match = re.fullmatch(r"\s*([0-9]+)\s+(\S.*)", line, flags=re.ASCII)
        if not match or int(match[1]) in seen:
            raise UpdateError("unparsable ps output")
        pid, arguments = int(match[1]), match[2]
        seen.add(pid)
        ps_canary |= pid == os.getpid()
        # ps joins argv without shell quoting; quote/backslash bytes are literal.
        tokens = arguments.split()
        direct_kept = set()
        # ps flattens argv without quoting paths containing spaces. Also match
        # known absolute paths literally, bounded by argument separators. Never
        # resolve argv paths: an unrelated network mount could block activation.
        for root in state_roots:
            for direct in re.finditer(r"(?<!\S)" + re.escape(root)
                                      + r"/([^/\s]+)(?=/|\s|$)", arguments):
                direct_kept.add(state / direct[1])
        kept.update(direct_kept)
        # Native CLIs expose their generations to lsof; JS CLIs may not.
        # Coverage belongs to this PID, never to every process of the CLI.
        if paths_by_pid.get(pid):
            continue
        for link in links:
            named_cli = tokens[0] == link.name
            if (named_cli
                    or re.search(r"(?<!\S)" + re.escape(str(link)) + r"(?=\s|$)", arguments)):
                metadata = package_at_link(link, None, state)
                held[link.name] = metadata["name"] if metadata else None
    if not ps_canary:
        raise UpdateError("ps scan missing this process's canary")
    for binary in sorted(held):
        print(f"ai-clis: holding all generations of {binary}: process arguments use its launch link")
    if held:
        for generation in state.iterdir():
            if generation.is_symlink() or not generation.is_dir():
                continue
            names = set()
            bins = generation / "bin"
            if bins.is_dir():
                for link in bins.iterdir():
                    metadata = package_at_link(link, None, generation)
                    if metadata:
                        names.add(metadata["name"])
            # An unknown stage may belong to a held CLI; uncertainty keeps it.
            if len(names) != 1 or None in held.values() or names.intersection(held.values()):
                kept.add(generation)
    return kept


def remaining_generations(state):
    """Account only for direct, real updater generation directories."""
    generations = [path for path in state.iterdir()
                   if re.fullmatch(r"package-[A-Za-z0-9_]{8}", path.name)
                   and not path.is_symlink() and path.is_dir()]
    size = 0
    def failed_walk(error):
        raise error
    for generation in generations:
        for root, directories, files in os.walk(generation, onerror=failed_walk):
            size += Path(root).lstat().st_size
            size += sum((Path(root) / name).lstat().st_size for name in files)
            size += sum((Path(root) / name).lstat().st_size for name in directories
                        if (Path(root) / name).is_symlink())
    return len(generations), size


def prune_generations(prefix, state, packages):
    """Best-effort GC under the publication lock; uncertainty keeps everything."""
    removed = 0
    try:
        state = state.resolve()
        kept = set()
        selected_receipts = set()
        receipts = []
        for link in (prefix / "bin").iterdir():
            if link.is_symlink():
                kept.add(generation_for(link, state))
        for path in state.iterdir():
            if not re.fullmatch(r"update-[0-9a-f]{32}\.json", path.name):
                continue
            if path.is_symlink() or not path.is_file():
                raise UpdateError("unexpected rollback receipt type")
            data = read_json(path)
            if (not isinstance(data, dict) or data.get("schema") != 1
                    or data.get("prefix") != str(prefix)):
                raise UpdateError("unexpected rollback receipt")
            records = data["updates"]
            if not isinstance(records, list) or any(
                not isinstance(item, dict)
                or not isinstance(item.get("bin"), str)
                or not isinstance(item.get("target"), str)
                or "previous" not in item
                or (item["previous"] is not None and not isinstance(item["previous"], str))
                for item in records
            ):
                raise UpdateError("invalid rollback receipt records")
            receipts.append((path.stat().st_mtime_ns, path, records))
        receipts.sort(key=lambda entry: (entry[0], entry[1].name), reverse=True)
        for package in packages:
            link = prefix / "bin" / package["bin"]
            current = link_value(link)
            if current is None:
                continue
            for _, receipt, records in receipts:
                match = next((item for item in records
                              if item["bin"] == package["bin"] and item["target"] == current), None)
                if match is not None:
                    selected_receipts.add(receipt)
                    if match["previous"] is not None:
                        kept.add(generation_for(link.parent / match["previous"], state))
                    break
        # Finish all retention planning before deleting any directory or receipt.
        paths_by_pid = generations_in_use(state)
        kept.update(generation_for(path, state)
                    for paths in paths_by_pid.values() for path in paths)
        kept.update(process_generations(prefix, state, paths_by_pid))
        for path in state.iterdir():
            if (re.fullmatch(r"package-[A-Za-z0-9_]{8}", path.name)
                    and not path.is_symlink() and path.is_dir() and path not in kept):
                shutil.rmtree(path)
                removed += 1
                print(f"ai-clis: pruned generation {path}")
        # Count untouched directories too: receipts referencing them still have
        # usable evidence. Only updater-owned receipt files can be removed.
        retained = {path for path in state.iterdir() if path.is_dir() and not path.is_symlink()}
        for _, receipt, records in receipts:
            referenced = {generation_for(prefix / "bin" / item[field], state)
                          for item in records for field in ("target", "previous")
                          if item[field] is not None}
            if receipt not in selected_receipts and not referenced.intersection(retained):
                receipt.unlink()
    except (UpdateError, OSError, ValueError, KeyError, TypeError,
            RuntimeError, subprocess.TimeoutExpired) as exc:
        # Publication already succeeded; GC cannot turn it into a failed update.
        try:
            count, size = remaining_generations(state)
            remaining = f"{count} generation(s) remain, {size} bytes total"
        except (OSError, ValueError, RuntimeError):
            remaining = "remaining generation count/size unavailable (filesystem error)"
        print(f"ai-clis: warning: generation prune skipped or incomplete ({type(exc).__name__}: {exc}); {remaining}",
              file=sys.stderr)
    finally:
        print(f"ai-clis: pruned {removed} generation(s) total")


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
        prune_generations(prefix, state, packages)
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
    prune_generations(prefix, state, packages)


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
            # Keep this process's descriptor open through update and its lsof
            # scan; its resolved lock path is the required scan canary.
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
