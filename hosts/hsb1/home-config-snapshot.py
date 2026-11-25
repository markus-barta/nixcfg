#!/usr/bin/env python3
"""OPS-158: an allowlisted, secret-gated local history. Never execute settings.js."""

import argparse
import contextlib
from dataclasses import dataclass, replace
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
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
BCRYPT = re.compile(r"\$2[abxy]?\$\d{2}\$[./A-Za-z0-9]{53}")
AUTH_KEYS = {"adminAuth", "httpNodeAuth", "httpStaticAuth"}


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
    deadline: float | None = None


class Refused(Exception):
    """Messages are fixed categories or validated filenames, never file contents."""


def log(message):
    print("home-config: " + message, flush=True)


def safe_path(path):
    name = str(path)
    return name if re.fullmatch(r"[A-Za-z0-9_./-]+", name) and ".." not in Path(name).parts else "[invalid-name]"


@contextlib.contextmanager
def path_errors(path):
    try:
        yield
    except OSError as error:
        raise Refused(f"I/O failure: path={safe_path(path)} errno={error.errno}") from None


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
            with path_errors(path):
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def signature(info, name):
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_BYTES:
        raise Refused("source must be a regular, single-link file of at most 32 MiB: " + safe_path(name))
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def manifest(roots, skipped=None):
    found = {}

    def walk(descriptor, prefix):
        with path_errors(prefix):
            names = sorted(os.listdir(descriptor))
        for name in names:
            relative = prefix + "/" + name
            with path_errors(relative):
                info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if allowed_directory(relative) and stat.S_ISDIR(info.st_mode):
                    with directory_entry(descriptor, name) as child:
                        walk(child, relative)
                elif allowed_path(relative):
                    found[relative] = signature(info, relative)
                elif skipped is not None:
                    skipped["entries"] += 1
                    if name.endswith((".yaml", ".yml")):
                        skipped["yaml"] += 1

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
    with path_errors(name):
        with directory(roots[source].joinpath(*parts[:-1])) as parent:
            descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, "rb") as handle:
            if signature(os.fstat(handle.fileno()), name) != expected:
                raise Refused("source changed while being read: " + safe_path(name))
            content = handle.read(MAX_BYTES + 1)
            if len(content) > MAX_BYTES or signature(os.fstat(handle.fileno()), name) != expected:
                raise Refused("source changed while being read: " + safe_path(name))
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


def auth_literals(text):
    """Find literal password/pass properties only inside the three auth objects."""
    tokens = [token for token in TOKENS.finditer(text) if token.lastgroup not in {"space", "comment"}]
    matches = []
    for index, token in enumerate(tokens):
        key = string_value(token.group()) if token.lastgroup == "string" else token.group()
        if key not in AUTH_KEYS or index + 2 >= len(tokens) or tokens[index + 1].group() != ":":
            continue
        if tokens[index + 2].group() in {"false", "null"}:
            if index + 3 >= len(tokens) or tokens[index + 3].group() not in {",", "}"}:
                raise Refused("settings auth configuration must be a literal object or disabled")
            continue
        if tokens[index + 2].group() != "{":
            raise Refused("settings auth configuration must be a literal object or disabled")
        depth = 0
        for offset in range(index + 2, len(tokens)):
            current = tokens[offset]
            value = string_value(current.group()) if current.lastgroup == "string" else current.group()
            if current.group() == "{":
                depth += 1
            elif current.group() == "}":
                depth -= 1
                if depth == 0:
                    break
            if value in {"password", "pass"} and offset + 1 < len(tokens) and tokens[offset + 1].group() == ":":
                if (offset + 3 >= len(tokens) or tokens[offset + 2].lastgroup != "string"
                        or tokens[offset + 3].group() not in {",", "}"}):
                    raise Refused("settings auth password must be a literal string")
                matches.append(tokens[offset + 2])
        else:
            raise Refused("unterminated settings auth object")
    return matches


def digest(content):
    return hashlib.sha256(content).digest()


def redact_settings(content):
    text = content.decode("utf-8")
    literal = credential_literal(text)
    secret = string_value(literal.group()).encode("utf-8")
    if not secret or secret == PLACEHOLDER.encode():
        raise Refused("empty or placeholder source credentialSecret rejected")
    literals = {literal.start(): literal}
    literals.update({token.start(): token for token in auth_literals(text)})
    # Raw matches include commented Node-RED template examples. Decode strings
    # too, so an escaped bcrypt spelling cannot survive outside an auth block.
    for token in TOKENS.finditer(text):
        if token.lastgroup == "string" and BCRYPT.search(string_value(token.group())):
            literals[token.start()] = token
    originals = {match.group().encode("utf-8") for match in BCRYPT.finditer(text)}
    for token in literals.values():
        originals.update((string_value(token.group()).encode("utf-8"), token.group().encode("utf-8")))
    guard = [(len(value), digest(value)) for value in originals if value and value != PLACEHOLDER.encode()]
    filtered = text
    for token in sorted(literals.values(), key=lambda match: match.start(), reverse=True):
        filtered = filtered[:token.start()] + json.dumps(PLACEHOLDER) + filtered[token.end():]
    filtered = BCRYPT.sub(PLACEHOLDER, filtered)
    result = filtered.encode("utf-8")
    check_settings(result, guard)
    return result, guard


def check_settings(content, guard):
    text = content.decode("utf-8")
    literal = credential_literal(text)
    if string_value(literal.group()) != PLACEHOLDER:
        raise Refused("settings credentialSecret placeholder missing")
    if BCRYPT.search(text) or any(string_value(token.group()) != PLACEHOLDER for token in auth_literals(text)):
        raise Refused("settings auth password or bcrypt placeholder missing")
    # Compare hashes, never reveal the original value (including escaped source spelling).
    values = [content] + [string_value(token.group()).encode("utf-8")
                          for token in TOKENS.finditer(text) if token.lastgroup == "string"]
    for value in values:
        for length, original_hash in guard:
            if any(hmac.compare_digest(digest(value[start:start + length]), original_hash)
                   for start in range(len(value) - length + 1)):
                raise Refused("settings credential hash gate failed")


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
    skipped = {"entries": 0, "yaml": 0}
    if manifest(roots, skipped) != after:
        raise Refused("source set changed while being read; retry on next trigger")
    log(f"ignored entries={skipped['entries']} skipped_yaml={skipped['yaml']}")
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
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": AUTHOR, "GIT_AUTHOR_EMAIL": EMAIL,
            "GIT_COMMITTER_NAME": AUTHOR, "GIT_COMMITTER_EMAIL": EMAIL}


def operation_timeout(args, maximum):
    remaining = maximum if args.deadline is None else min(maximum, args.deadline - time.monotonic())
    if remaining <= 0:
        raise Refused("operation time budget exhausted; retry on next trigger")
    return remaining


def git(args, *arguments, data=None, check=True, index=None, timeout=60):
    environment = private_environment(args.runtime)
    if index is not None:
        environment["GIT_INDEX_FILE"] = str(index)
    try:
        result = subprocess.run(
            [args.git, "-c", "protocol.allow=never", "-c", "core.autocrlf=false",
             "-c", "core.hooksPath=/dev/null", "-c", "core.fsync=loose-object,reference",
             "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-C", str(args.repo), *arguments],
            input=data, capture_output=True, env=environment, timeout=operation_timeout(args, timeout),
        )
    except (OSError, subprocess.SubprocessError):
        raise Refused("Git operation failed or timed out: " + arguments[0] + " path=" + safe_path(args.repo)) from None
    if check and result.returncode:
        raise Refused("Git operation failed: " + arguments[0])
    return result


def no_remote(args):
    if git(args, "remote").stdout.strip():
        raise Refused("remote configured; local-only repository required")


def prepare_repo(args, verify):
    with directory(args.repo):
        info = args.repo.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o2750:
            raise Refused("repository must be owned by the service user and mode 2750: " + safe_path(args.repo))
    git_dir = args.repo / ".git"
    if not git_dir.exists():
        if not verify:
            for path in args.repo.iterdir():
                if re.fullmatch(r"\.snapshot-init-[a-z0-9_]{8}", path.name):
                    info = path.lstat()
                    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                        raise Refused("unexpected initialization artifact: " + safe_path(path))
                    shutil.rmtree(path)  # Reserved, service-owned initialization namespace only.
                    log("removed stale service initialization")
        if verify or any(args.repo.iterdir()):
            raise Refused("expected an existing repository or an empty snapshot directory")
        template = args.runtime / "empty-template"
        template.mkdir(exist_ok=True, mode=0o700)
        # History only: no live worktree or shared index can be half-updated.
        # Keep .git/ so existing backup and reader paths remain unchanged.
        # Initialize beside the final directory and publish only a complete
        # repository. An interrupted init cannot strand config.lock in .git/.
        # RestrictSUIDSGID rejects even chmod of an already-set setgid bit.
        # mkdir(0750) inherits 02750 from the repository under UMask=0027;
        # Git's shared-permission adjustment then needs no directory chmod.
        initializing = args.repo / (".snapshot-init-" + secrets.token_hex(4))
        with path_errors(initializing):
            os.mkdir(initializing, 0o750)
        try:
            git(args, "init", "--quiet", "--bare", "--shared=0640", "--initial-branch=main",
                "--template=" + str(template), str(initializing))
            git(args, "config", "--file", str(initializing / "config"), "core.sharedRepository", "0640")
            os.replace(initializing, git_dir)
        finally:
            if initializing.exists():
                shutil.rmtree(initializing)  # Only the directory created by this invocation.
    with directory(git_dir):
        info = git_dir.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o2750:
            raise Refused("Git directory must be owned by the service user and mode 2750: " + safe_path(git_dir))
        # The production service user is root. Check before Git reads local
        # config: hooksPath alone cannot disable commands such as GC hooks.
        info = (git_dir / "config").lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o640):
            raise Refused("Git config must be a service-owned regular file with mode 0640")
        if (git(args, "rev-parse", "--absolute-git-dir").stdout.decode().strip() != str(git_dir)
                or git(args, "rev-parse", "--is-bare-repository").stdout.strip() != b"true"):
            raise Refused("expected a history-only bare repository; preserve existing worktrees for operator review")
    if git(args, "config", "--local", "--get", "core.sharedRepository").stdout.strip() != b"0640":
        raise Refused("repository core.sharedRepository must be 0640")
    if git(args, "symbolic-ref", "HEAD").stdout.strip() != b"refs/heads/main":
        raise Refused("repository HEAD must name refs/heads/main")
    no_remote(args)
    for info_file in (git_dir / "info/attributes", git_dir / "info/grafts"):
        if info_file.exists():
            raise Refused("unexpected Git tree transformation; refusing snapshot")
    # Never overwrite/delete another operator's untracked files or staged work.
    if any(path.name != ".git" for path in args.repo.iterdir()):
        raise Refused("repository has pending changes; preserve them for operator review")
    if any(path.exists() or path.is_symlink() for path in (git_dir / "index", git_dir / "refs/heads/main.lock")):
        raise Refused("repository has unexpected index or ref lock; preserve operator work")
    if current_head(args) is None:
        success = git_dir / "snapshot-success"
        objects = git_dir / "objects"
        with directory(objects):
            populated = any(not path.is_dir() or path.is_symlink() for path in objects.rglob("*"))
        if success.exists() or success.is_symlink() or populated:
            # Check before writing the first blob. Publication rechecks HEAD
            # after creating objects, so it must retain its normal None result.
            raise Refused("snapshot HEAD missing from existing history; preserve repository for operator recovery")


def index_contents(args, revision=None, index=None):
    if revision:
        records = git(args, "ls-tree", "-rz", "--full-tree", revision).stdout.split(b"\0")
    else:
        records = git(args, "ls-files", "--stage", "-z", index=index).stdout.split(b"\0")
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
        with path_errors(destination), directory(target):
            destination.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        with path_errors(destination), directory(destination.parent):
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
        try:
            result = subprocess.run(
                [args.gitleaks, "dir", str(tree), "--config", str(args.scanner_config),
                 "--no-banner", "--no-color", "--redact=100", "--ignore-gitleaks-allow",
                 "--gitleaks-ignore-path", report_dir, "--max-target-megabytes", "0",
                 "--report-format", "json", "--report-path", str(report), "--exit-code", "23", "--timeout", "60"],
                cwd=tree, capture_output=True, env=private_environment(args.runtime), timeout=operation_timeout(args, 75),
            )
        except (OSError, subprocess.SubprocessError):
            raise Refused("secret scanner failed or timed out: path=" + safe_path(tree) + "; no commit") from None
        if result.returncode not in (0, 23) or not report.is_file():
            raise Refused("secret scanner failed: path=" + safe_path(tree) + "; no commit")
        try:
            with path_errors(report):
                findings = json.loads(report.read_bytes())
        except (ValueError, UnicodeError):
            raise Refused("invalid secret scanner report: path=" + safe_path(report) + "; no commit") from None
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


def current_head(args):
    result = git(args, "rev-parse", "--verify", "HEAD", check=False)
    if result.returncode == 0:
        value = result.stdout.strip().decode("ascii")
        if re.fullmatch(r"[0-9a-f]{40}", value):
            return value
    main = args.repo / ".git/refs/heads/main"
    if (not main.exists() and not main.is_symlink()
            and git(args, "show-ref", "--verify", "--quiet", "refs/heads/main", check=False).returncode == 1):
        return None
    raise Refused("cannot determine snapshot HEAD")


def publish_head(args, commit, previous):
    """Publish one complete loose ref under the exclusive service lock.

    The history has exactly one writer (this service); manual writes are
    forbidden. Unlike a Git .lock transaction, atomic replacement leaves no
    blocking ref lock after SIGKILL. Dot-prefixed temporary refs are ignored
    by Git and recovered only by this service on the next full invocation.
    """
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise Refused("invalid snapshot commit identifier")
    parent = args.repo / ".git/refs/heads"
    with directory(parent) as descriptor, path_errors(parent):
        with tempfile.NamedTemporaryFile(dir=parent, prefix=".snapshot-ref-", delete=False) as handle:
            temporary = Path(handle.name)
            try:
                os.fchmod(handle.fileno(), 0o640)
                handle.write((commit + "\n").encode("ascii"))
                handle.flush()
                os.fsync(handle.fileno())
                no_remote(args)
                if current_head(args) != previous or (parent / "main.lock").exists():
                    raise Refused("snapshot ref changed; preserve concurrent operator work")
                os.replace(temporary, parent / "main")
                os.fsync(descriptor)
            finally:
                temporary.unlink(missing_ok=True)


def clean_stale(args, verify_only):
    removed = 0
    for path in args.runtime.iterdir():
        if not re.fullmatch(r"(?:snapshot|index|scan)-[a-z0-9_]{8}", path.name):
            continue
        with path_errors(path):
            info = path.lstat()
            if info.st_uid != os.geteuid():
                raise Refused("unexpected runtime artifact owner: " + safe_path(path))
            if stat.S_ISDIR(info.st_mode):
                shutil.rmtree(path)  # Reserved service scratch namespace, under its exclusive lock.
            elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                path.unlink()
            else:
                raise Refused("unexpected runtime artifact type: " + safe_path(path))
            removed += 1
    if not verify_only:
        parent = args.repo / ".git/refs/heads"
        with directory(parent):
            for path in parent.iterdir():
                if re.fullmatch(r"\.snapshot-ref-[a-z0-9_]{8}", path.name):
                    info = path.lstat()
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                        raise Refused("unexpected temporary ref: " + safe_path(path))
                    path.unlink()
                    removed += 1
    if removed:
        log(f"removed stale service artifacts={removed}")


def snapshot(args, verify_only=False, debounce_seconds=20):
    roots = {"nodered": args.nodered, "homeassistant": args.homeassistant}
    prepare_repo(args, verify_only)
    clean_stale(args, verify_only)
    contents, guard = candidate(roots, debounce_seconds)
    head = current_head(args)
    previous = index_contents(args, head) if head else {}
    if not verify_only and previous.keys() == contents.keys() and all(
            hmac.compare_digest(digest(previous[name]), digest(content)) for name, content in contents.items()):
        no_remote(args)
        log("unchanged; no commit")
        return
    with tempfile.TemporaryDirectory(prefix="snapshot-", dir=args.runtime) as temporary:
        scratch = Path(temporary)
        if verify_only:
            if not head:
                raise Refused("verification requires an existing snapshot HEAD")
            staged = previous
            check_settings(staged["nodered/settings.js"], guard)
            write_tree(scratch, staged)
            scan_tree(args, scratch)
            no_remote(args)
            log("verified HEAD: allowlist, scanner, settings hash gate and no remote")
            return
        write_tree(scratch, contents)
        scan_tree(args, scratch)  # No unscanned source content reaches Git objects.
        with tempfile.TemporaryDirectory(prefix="index-", dir=args.runtime) as staged_dir:
            index = Path(staged_dir) / "private-index"
            git(args, "read-tree", head or "--empty", index=index)
            changes = []
            for name in sorted(previous.keys() - contents.keys()):
                changes.append("0 " + "0" * 40 + "\t" + name + "\0")
            names = sorted(name for name in contents if name not in previous
                           or digest(previous[name]) != digest(contents[name]))
            for name in names:
                object_id = git(args, "hash-object", "-w", "--stdin", data=contents[name]).stdout.decode().strip()
                changes.append("100644 " + object_id + "\t" + name + "\0")
            git(args, "update-index", "-z", "--index-info", data="".join(changes).encode(), index=index)
            staged = index_contents(args, index=index)
            if staged.keys() != contents.keys() or any(digest(staged[name]) != digest(content) for name, content in contents.items()):
                raise Refused("staged tree differs from the scanned candidate; no commit")
            check_settings(staged["nodered/settings.js"], guard)
            exported = Path(staged_dir) / "tree"
            exported.mkdir(mode=0o700)
            write_tree(exported, staged)
            scan_tree(args, exported)  # Scan the exact staged blobs, never the private index file.
            tree = git(args, "write-tree", index=index).stdout.decode().strip()
        no_remote(args)
        names = sorted(set(names) | (previous.keys() - contents.keys()))
        sources = ",".join(sorted({name.split("/", 1)[0] for name in names}))
        message = "snapshot " + sources + ": " + ", ".join(names) + "\n"
        parents = ["-p", head] if head else []
        commit = git(args, "commit-tree", tree, *parents, "-F", "-", data=message.encode()).stdout.decode().strip()
        publish_head(args, commit, head)
        log("committed " + sources + ": " + ", ".join(names))


def in_service_unit(gc_only):
    expected = "hsb1-home-config-gc.service" if gc_only else "hsb1-home-config.service"
    try:
        cgroups = Path("/proc/self/cgroup").read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        return False
    # Match a complete cgroup path component, for both cgroup v1 and v2.
    # INVOCATION_ID can be inherited or supplied by a manual shell.
    return any(len(fields := line.split(":", 2)) == 3 and expected in fields[2].split("/")
               for line in cgroups)


def run(args, verify_only=False, gc_only=False, debounce_seconds=20):
    os.umask(0o027)
    try:
        if not verify_only and not in_service_unit(gc_only):
            raise Refused("full snapshot and maintenance require the systemd unit; use --verify-only manually")
        args = replace(args, deadline=time.monotonic() + (28 * 60 if gc_only else 8 * 60))
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
            # Do this even if repository checks later refuse: killed runs must
            # not retain unscanned candidate copies until the next reboot.
            clean_stale(args, True)
            if gc_only:
                prepare_repo(args, True)
                clean_stale(args, False)
                git(args, "gc", "--prune=2.weeks.ago", timeout=27 * 60)
                with path_errors(args.repo / ".git/gc-success"):
                    (args.repo / ".git/gc-success").touch(mode=0o640)
                log("periodic Git maintenance complete")
            else:
                snapshot(args, verify_only, debounce_seconds)
                if not verify_only:
                    with path_errors(args.repo / ".git/snapshot-success"):
                        (args.repo / ".git/snapshot-success").touch(mode=0o640)
        return 0
    except Refused as error:
        log(str(error))
    except OSError as error:
        log(f"I/O failure: path={safe_path(error.filename or '[unknown]')} errno={error.errno}; no commit")
    except (ValueError, UnicodeError, KeyError, TypeError, subprocess.SubprocessError):
        # Library error bodies may contain source text, credentials or process arguments.
        log("I/O, format or subprocess failure; no commit")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--verify-only", action="store_true")
    modes.add_argument("--gc", action="store_true", help="periodic maintenance; systemd unit only")
    options = parser.parse_args()
    return run(Settings(), verify_only=options.verify_only, gc_only=options.gc)


if __name__ == "__main__":
    sys.exit(main())
