#!/usr/bin/env python3
"""OPS-158: an allowlisted, secret-gated local history. Never execute settings.js."""

import argparse
import contextlib
from dataclasses import dataclass
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import time


PLACEHOLDER = "[REDACTED]"
AUTHOR = "hsb1-home-config"
EMAIL = "root@hsb1"
MAX_BYTES = 32 * 1024 * 1024
NODE_FILES = {"flows.json", "settings.js", "package.json"}
HA_FILES = {"configuration.yaml", "automations.yaml", "scripts.yaml", "scenes.yaml", "customize.yaml"}
REGISTRIES = {"core." + name + "_registry" for name in ("area", "floor", "device", "entity", "label")}
YAML_DIRS = {"themes", "blueprints", "packages"}
STEM = r"[A-Za-z0-9_-]+"


@dataclass(frozen=True)
class Settings:
    # Production paths are fixed. The internal API accepts synthetic fixture
    # directories; no root-facing CLI option can redirect reads or writes.
    repo: Path = Path("/home/mba/home-config")
    runtime: Path = Path("/run/hsb1-home-config")
    nodered: Path = Path("/home/mba/docker/mounts/nodered/data")
    homeassistant: Path = Path("/home/mba/docker/mounts/homeassistant")
    scanner_config: Path = Path("/etc/hsb1-home-config/gitleaks.toml")
    git: str = "git"
    gitleaks: str = "gitleaks"


class Refused(Exception):
    """Messages are fixed categories or validated filenames, never file contents."""


def log(message):
    print("home-config: " + message, flush=True)


def allowed_path(name):
    """Positive rules only: adding an unknown file never opts it into history."""
    parts = PurePosixPath(name).parts
    if len(parts) == 2:
        return ((parts[0] == "nodered" and parts[1] in NODE_FILES)
                or (parts[0] == "homeassistant" and parts[1] in HA_FILES))
    if len(parts) == 3 and parts[:2] == ("homeassistant", ".storage"):
        return (parts[2] in REGISTRIES or parts[2] in {"lovelace", "lovelace_resources", "lovelace_dashboards"}
                or re.fullmatch(r"lovelace\.(?!(?i:bak))" + STEM, parts[2]) is not None)
    return (len(parts) >= 3 and parts[0] == "homeassistant" and parts[1] in YAML_DIRS
            and all(re.fullmatch(STEM, part) for part in parts[2:-1])
            and re.fullmatch(STEM + r"\.ya?ml", parts[-1]) is not None)


def allowed_directory(name):
    parts = PurePosixPath(name).parts
    return (parts == ("homeassistant", ".storage")
            or (len(parts) >= 2 and parts[0] == "homeassistant" and parts[1] in YAML_DIRS
                and all(re.fullmatch(STEM, part) for part in parts[2:])))


@contextlib.contextmanager
def directory(path):
    """Open every ancestor without following symlinks, including source roots."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise Refused("absolute paths without parent traversal required")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def signature(info):
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_BYTES:
        raise Refused("source must be a regular, single-link file of at most 32 MiB")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def manifest(roots):
    found = {}

    def walk(descriptor, prefix):
        for name in sorted(os.listdir(descriptor)):
            relative = prefix + "/" + name
            if allowed_directory(relative):
                with directory_entry(descriptor, name) as child:
                    walk(child, relative)
            elif allowed_path(relative):
                found[relative] = signature(os.stat(name, dir_fd=descriptor, follow_symlinks=False))

    for source, root in roots.items():
        with directory(root) as descriptor:
            walk(descriptor, source)
    if not {"nodered/flows.json", "nodered/settings.js", "homeassistant/configuration.yaml"} <= found.keys():
        raise Refused("required source file missing; refusing an incomplete snapshot")
    return found


@contextlib.contextmanager
def directory_entry(parent, name):
    descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def read_source(roots, name, expected):
    source, *parts = PurePosixPath(name).parts
    with directory(roots[source].joinpath(*parts[:-1])) as parent:
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(descriptor, "rb") as handle:
        if signature(os.fstat(handle.fileno())) != expected:
            raise Refused("source changed while being read; retry on the next trigger")
        content = handle.read(MAX_BYTES + 1)
        if len(content) > MAX_BYTES or signature(os.fstat(handle.fileno())) != expected:
            raise Refused("source changed while being read; retry on the next trigger")
    return content


TOKENS = re.compile(
    r"(?P<space>\s+)|(?P<comment>//[^\r\n]*|/\*[\s\S]*?\*/)"
    r'''|(?P<string>"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*')'''
    r"|(?P<template>`(?:\\[\s\S]|[^`\\])*`)"
    r"|(?P<word>[A-Za-z_$][A-Za-z0-9_$]*)|(?P<other>[\s\S])"
)


def string_value(literal):
    """Decode only literal JS strings, including escaped credential values."""
    result = []
    offset = 1
    escapes = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}
    while offset < len(literal) - 1:
        char = literal[offset]
        offset += 1
        if char != "\\":
            if char in "\r\n":
                raise Refused("unsupported settings string newline")
            result.append(char)
            continue
        char = literal[offset]
        offset += 1
        if char in "xu":
            width = 2 if char == "x" else 4
            digits = literal[offset:offset + width]
            if len(digits) != width or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                raise Refused("unsupported settings string escape")
            result.append(chr(int(digits, 16)))
            offset += width
        elif char in "\r\n" or char.isdigit() and char != "0" or char == "0" and literal[offset:offset + 1].isdigit():
            raise Refused("unsupported settings string escape")
        else:
            result.append(escapes.get(char, char))
    return "".join(result).encode("utf-16", "surrogatepass").decode("utf-16")


def credential_literal(text):
    tokens = [token for token in TOKENS.finditer(text) if token.lastgroup not in {"space", "comment"}]
    matches = []
    for index, token in enumerate(tokens):
        value = token.group()
        if token.lastgroup == "string":
            value = string_value(value)
        if value != "credentialSecret":
            continue
        if (index + 3 >= len(tokens) or tokens[index + 1].group() != ":"
                or tokens[index + 2].lastgroup != "string" or tokens[index + 3].group() not in {",", "}"}):
            raise Refused("credentialSecret must be a single literal property; settings expressions are never executed")
        matches.append(tokens[index + 2])
    if len(matches) != 1:
        raise Refused("exactly one literal credentialSecret property required")
    return matches[0]


def digest(content):
    return hashlib.sha256(content).digest()


def redact_settings(content):
    text = content.decode("utf-8")
    literal = credential_literal(text)
    secret = string_value(literal.group()).encode("utf-8")
    if not secret or secret == PLACEHOLDER.encode():
        raise Refused("empty or placeholder source credentialSecret rejected")
    guard = [(len(value), digest(value)) for value in (secret, literal.group().encode("utf-8"))]
    filtered = text[:literal.start()] + json.dumps(PLACEHOLDER) + text[literal.end():]
    result = filtered.encode("utf-8")
    check_settings(result, guard)
    return result, guard


def check_settings(content, guard):
    text = content.decode("utf-8")
    literal = credential_literal(text)
    if string_value(literal.group()) != PLACEHOLDER:
        raise Refused("settings credentialSecret placeholder missing")
    # Compare hashes, never reveal the original value (including escaped source spelling).
    values = [content] + [string_value(token.group()).encode("utf-8")
                          for token in TOKENS.finditer(text) if token.lastgroup == "string"]
    for value in values:
        for length, original_hash in guard:
            if any(hmac.compare_digest(digest(value[start:start + length]), original_hash)
                   for start in range(len(value) - length + 1)):
                raise Refused("settings credentialSecret hash gate failed")


def candidate(roots, debounce):
    deadline = time.monotonic() + 120
    before = manifest(roots)
    while True:
        time.sleep(debounce)
        after = manifest(roots)
        if before == after:
            break
        if time.monotonic() >= deadline:
            raise Refused("sources did not settle within two minutes; retry on next trigger")
        before = after
    contents = {name: read_source(roots, name, info) for name, info in after.items()}
    if manifest(roots) != after:
        raise Refused("source set changed while being read; retry on next trigger")
    contents["nodered/settings.js"], guard = redact_settings(contents["nodered/settings.js"])
    for name, content in contents.items():
        if name.endswith(".json") or "/.storage/" in name:
            try:
                json.loads(content)
            except (ValueError, UnicodeError):
                raise Refused("invalid JSON in " + name) from None
    return contents, guard


def private_environment(runtime):
    # Do not inherit Git, scanner, credential-helper, config or ignore-file overrides.
    return {"PATH": os.environ.get("PATH", os.defpath), "HOME": str(runtime), "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ATTR_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": AUTHOR, "GIT_AUTHOR_EMAIL": EMAIL,
            "GIT_COMMITTER_NAME": AUTHOR, "GIT_COMMITTER_EMAIL": EMAIL}


def git(args, *arguments, data=None, check=True):
    result = subprocess.run(
        [args.git, "-c", "protocol.allow=never", "-c", "core.autocrlf=false", "-C", str(args.repo), *arguments],
        input=data, capture_output=True, env=private_environment(args.runtime), timeout=60,
    )
    if check and result.returncode:
        raise Refused("Git operation failed: " + arguments[0])
    return result


def no_remote(args):
    if git(args, "remote").stdout.strip():
        raise Refused("remote configured; local-only repository required")


def prepare_repo(args, verify):
    with directory(args.repo):
        info = args.repo.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise Refused("repository must be owned by the service user without group/world write access")
    git_dir = args.repo / ".git"
    if not git_dir.exists():
        if verify or any(args.repo.iterdir()):
            raise Refused("expected an existing repository or an empty snapshot directory")
        template = args.runtime / "empty-template"
        template.mkdir(exist_ok=True, mode=0o700)
        git(args, "init", "--quiet", "--initial-branch=main", "--template=" + str(template))
    with directory(git_dir):
        if git(args, "rev-parse", "--show-toplevel").stdout.decode().strip() != str(args.repo):
            raise Refused("snapshot directory must be its own non-bare repository")
    no_remote(args)
    for info_file in (git_dir / "info/attributes", git_dir / "info/grafts"):
        if info_file.exists():
            raise Refused("unexpected Git tree transformation; refusing snapshot")
    # Never overwrite/delete another operator's untracked files or staged work.
    if git(args, "status", "--porcelain", "--untracked-files=all").stdout:
        raise Refused("repository has pending changes; preserve them for operator review")


def index_contents(args, revision=None):
    if revision:
        records = git(args, "ls-tree", "-rz", "--full-tree", revision).stdout.split(b"\0")
    else:
        records = git(args, "ls-files", "--stage", "-z").stdout.split(b"\0")
    contents = {}
    for record in filter(None, records):
        metadata, raw_name = record.split(b"\t", 1)
        mode, kind, stage_or_hash = metadata.split()
        name = raw_name.decode("utf-8")
        if mode != b"100644" or not allowed_path(name) or (revision and kind != b"blob") or (not revision and stage_or_hash != b"0"):
            raise Refused("Git tree contains a non-allowlisted path, mode or unresolved entry")
        object_id = stage_or_hash if revision else kind
        content = git(args, "cat-file", "blob", object_id.decode("ascii")).stdout
        if len(content) > MAX_BYTES:
            raise Refused("Git blob exceeds snapshot size limit")
        contents[name] = content
    return contents


def write_tree(target, contents):
    for name, content in contents.items():
        if not allowed_path(name):
            raise Refused("non-allowlisted candidate path")
        destination = target / name
        destination.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        with directory(destination.parent):
            # All destination directories are service-owned; replace only known files.
            with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".snapshot-", delete=False) as handle:
                temporary = Path(handle.name)
                try:
                    os.fchmod(handle.fileno(), 0o640)
                    handle.write(content)
                    handle.flush()
                    os.fsync(handle.fileno())
                    os.replace(temporary, destination)
                finally:
                    temporary.unlink(missing_ok=True)


def scan_tree(args, tree):
    # Captured output and 100% redacted JSON never enter the journal. Only safe fields below do.
    with tempfile.TemporaryDirectory(prefix="scan-", dir=args.runtime) as report_dir:
        report = Path(report_dir) / "report.json"
        result = subprocess.run(
            [args.gitleaks, "dir", str(tree), "--config", str(args.scanner_config),
             "--no-banner", "--no-color", "--redact=100", "--ignore-gitleaks-allow",
             "--gitleaks-ignore-path", report_dir, "--max-target-megabytes", "0",
             "--report-format", "json", "--report-path", str(report), "--exit-code", "23", "--timeout", "60"],
            cwd=tree, capture_output=True, env=private_environment(args.runtime), timeout=75,
        )
        if result.returncode not in (0, 23) or not report.is_file():
            raise Refused("secret scanner failed; no commit")
        findings = json.loads(report.read_bytes())
        if not isinstance(findings, list):
            raise Refused("invalid secret scanner report; no commit")
        for finding in findings:
            rule = finding.get("RuleID", "unknown")
            raw_file = Path(finding.get("File", ""))
            name = str(raw_file.relative_to(tree)) if raw_file.is_absolute() and raw_file.is_relative_to(tree) else str(raw_file)
            safe_rule = rule if re.fullmatch(r"[A-Za-z0-9_-]+", rule) else "unknown"
            safe_file = name if allowed_path(name) else "unknown"
            line = finding.get("StartLine", 0)
            log(f"secret gate: rule={safe_rule} file={safe_file} line={line if type(line) is int else 0}")
        if findings or result.returncode != 0:
            raise Refused("secret gate rejected tree; no commit")


def snapshot(args, verify_only=False, debounce_seconds=20):
    roots = {"nodered": args.nodered, "homeassistant": args.homeassistant}
    prepare_repo(args, verify_only)
    contents, guard = candidate(roots, debounce_seconds)
    with tempfile.TemporaryDirectory(prefix="snapshot-", dir=args.runtime) as temporary:
        scratch = Path(temporary)
        if verify_only:
            staged = index_contents(args, "HEAD")
            check_settings(staged["nodered/settings.js"], guard)
            write_tree(scratch, staged)
            scan_tree(args, scratch)
            no_remote(args)
            log("verified HEAD: allowlist, scanner, settings hash gate and no remote")
            return
        write_tree(scratch, contents)
        scan_tree(args, scratch)  # No unscanned source content reaches Git objects.
        previous = index_contents(args)
        for name in previous.keys() - contents.keys():
            with directory((args.repo / name).parent):
                (args.repo / name).unlink()
        write_tree(args.repo, contents)
        git(args, "add", "--all", "--", "nodered", "homeassistant")
        staged = index_contents(args)
        if staged.keys() != contents.keys() or any(digest(staged[name]) != digest(content) for name, content in contents.items()):
            raise Refused("staged tree differs from the scanned candidate; no commit")
        check_settings(staged["nodered/settings.js"], guard)
        with tempfile.TemporaryDirectory(prefix="index-", dir=args.runtime) as staged_dir:
            write_tree(Path(staged_dir), staged)
            scan_tree(args, Path(staged_dir))  # Scan the exact staged blobs, not a working-tree approximation.
        no_remote(args)
        diff = git(args, "diff", "--cached", "--quiet", "--exit-code", check=False)
        if diff.returncode == 0:
            log("unchanged; no commit")
            return
        if diff.returncode != 1:
            raise Refused("cannot determine staged changes; no commit")
        names = sorted(filter(None, git(args, "diff", "--cached", "--name-only", "-z").stdout.decode().split("\0")))
        sources = ",".join(sorted({name.split("/", 1)[0] for name in names}))
        message = "snapshot " + sources + ": " + ", ".join(names) + "\n"
        git(args, "commit", "--quiet", "--file=-", data=message.encode())
        log("committed " + sources + ": " + ", ".join(names))


def run(args, verify_only=False, debounce_seconds=20):
    os.umask(0o027)
    try:
        args.runtime.mkdir(mode=0o700, exist_ok=True)
        with directory(args.runtime):
            info = args.runtime.stat()
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise Refused("runtime directory must be service-owned and mode 0700")
        with (args.runtime / "snapshot.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if verify_only:
                    raise Refused("verification busy; retry after the snapshot completes") from None
                log("snapshot already running")
                return 0
            snapshot(args, verify_only, debounce_seconds)
        return 0
    except Refused as error:
        log(str(error))
    except (OSError, ValueError, UnicodeError, KeyError, TypeError, subprocess.SubprocessError):
        # Library error bodies may contain source text, credentials or process arguments.
        log("I/O, format or subprocess failure; no commit")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    options = parser.parse_args()
    return run(Settings(), verify_only=options.verify_only)


if __name__ == "__main__":
    sys.exit(main())
