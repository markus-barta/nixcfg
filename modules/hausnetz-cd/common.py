"""OPS-705: shared fail-closed checks; no host or credential access on import."""

import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote
import zipfile


class Manual(Exception):
    """A value-free reason safe to put in deployment evidence."""

    def __init__(self, reason, problems=None, changed_paths=None):
        super().__init__(reason)
        self.problems = problems
        self.changed_paths = changed_paths


REV = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
RUN_ID = re.compile(r"[0-9a-f]{32}")
# Hausnetz's existing compact CalVer package coordinate; no version migration.
CALVER = re.compile(r"[0-9]{12}\.0\.0")
BUILD_TIMEOUT = 600
G3_COMMAND_TIMEOUT = 60
G3_TIMEOUT = 2 * G3_COMMAND_TIMEOUT  # diff-closures + dry-activate
ACK_TIMEOUT = 120
HEALTH_TIMEOUT = 120
SWITCH_BUDGET = 600  # observation budget only: activation is never killed
SOURCE_BUDGET = 600
EXECUTOR_BUDGET = (SOURCE_BUDGET + BUILD_TIMEOUT + G3_TIMEOUT + ACK_TIMEOUT
                   + 3 * HEALTH_TIMEOUT + 2 * SWITCH_BUDGET + 120)
SSH_RETRY_TIMEOUT = 300
POLL_INTERVAL = 15
POLL_BUDGET = EXECUTOR_BUDGET + SSH_RETRY_TIMEOUT + 120
UNIT_RUNTIME_MAX = POLL_BUDGET + 300
EVIDENCE_SCHEMA = "inspr.pharos.nix-deployment-evidence.v1"
RESULT_SCHEMA = "inspr.pharos.guarded-deploy-result.v1"
TERMINAL = {"manual", "dry-run", "succeeded", "failed", "rollback_failed", "skipped", "unknown", "fetch_failed"}


def diagnostics(items):
    """Bound untrusted checker diagnostics at every evidence boundary."""
    if not isinstance(items, list):
        return []
    limit = 19 if len(items) > 20 else 20
    result = [item[:197] + "..." if len(item) > 200 else item
              for item in items[:limit] if isinstance(item, str)]
    if len(items) > 20:
        result.append("+" + str(len(items) - limit) + " more")
    return result


def require(condition, reason):
    if not condition:
        raise Manual(reason)


def revision(value):
    require(isinstance(value, str) and REV.fullmatch(value), "invalid_revision")
    return value


def coordinate(version):
    require(isinstance(version, str) and CALVER.fullmatch(version), "invalid_calendar_version")
    try:
        parts = [int(version[i:i + 2]) for i in range(0, 12, 2)]
        datetime.datetime(2000 + parts[0], *parts[1:])
    except ValueError as exc:
        raise Manual("invalid_calendar_version") from exc
    return version


def digest(value):
    require(isinstance(value, str) and SHA256.fullmatch(value), "invalid_manifest_digest")
    return value


def run_id(value):
    require(isinstance(value, str) and RUN_ID.fullmatch(value), "invalid_run_id")
    return value


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def run(executable, args, *, timeout=60, data=None, binary=False):
    # Keep the executable separate from data arguments. Production callers
    # select it from literals, the Nix-baked config, or a proved store output.
    # Diagnostics can contain credential-bearing URLs; never return them.
    try:
        result = subprocess.run(
            [str(executable), *[str(a) for a in args]], input=data, capture_output=True,
            text=not binary, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Manual("command_unavailable_or_timeout") from exc
    require(result.returncode == 0, "command_failed")
    return result.stdout


def http_get(url, timeout):
    response = run("curl", ["--disable", "--fail", "--silent", "--noproxy", "*",
                    "--proto", "=http", "--max-time", str(timeout),
                    "--max-filesize", "268435456", "--write-out", "\n%{http_code}", url],
                   timeout=timeout, binary=True)
    body, separator, code = response.rpartition(b"\n")
    require(separator and code == b"200", "http_status_not_200")
    return body


def strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate_json_key")
            result[key] = value
        return result

    try:
        return json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Manual("unreadable_json") from exc


# Production state is fixed. Offline fixtures replace this constant only in
# their test entrypoint; no production argv/config/env can select a root.
STATE_ROOT = "/var/lib/hausnetz-cd"


def state_path(path):
    resolved = os.path.realpath(path)
    if not resolved.startswith(STATE_ROOT + os.sep):
        raise Manual("unsafe_state_path")
    return Path(resolved)


def private_dir(path):
    path = Path(path)
    require(not path.is_symlink(), "unsafe_state_directory")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def atomic_bytes(path, data):
    path = Path(path)
    private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".cd-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, sort_keys=True) + "\n").encode())


def evidence(data):
    value = strict_json(data)
    require(isinstance(value, dict) and value.get("schema") == EVIDENCE_SCHEMA,
            "running_evidence_schema")
    return revision(value.get("source_revision"))


def git(repo, *args):
    return run("git", ["-C", repo, *args])


def cache_repo(path, url, *revs, worktree=False):
    path = Path(path)
    if not path.exists():
        run("git", ["clone", *([] if worktree else ["--bare"]), "--quiet", url, path], timeout=90)
    require(git(path, "config", "--get", "remote.origin.url").strip() == url,
            "cache_origin_mismatch")
    if worktree:
        if git(path, "rev-parse", "--is-shallow-repository").strip() == "true":
            git(path, "fetch", "--quiet", "--unshallow", "origin")
        git(path, "fetch", "--quiet", "origin")
    else:
        git(path, "fetch", "--quiet", "origin", "refs/heads/main:refs/heads/main")
    for rev in revs:
        revision(rev)
        try:
            git(path, "cat-file", "-e", rev + "^{commit}")
        except Manual:
            git(path, "fetch", "--quiet", "origin", rev)
    return path


def tree_mode(repo, rev, path):
    entry = git(repo, "ls-tree", rev, "--", path).split()
    require(len(entry) == 4 and entry[0] in {"100644", "100755"}
            and entry[1] == "blob", "nonregular_gate_input")
    return entry[0]


def blob(repo, rev, path):
    tree_mode(repo, rev, path)
    return run("git", ["-C", repo, "show", rev + ":" + path], binary=True).decode("utf-8")


def lock_pin(text):
    lock = strict_json(text)
    require(lock["nodes"][lock["root"]]["inputs"]["hausnetz"] == "hausnetz",
            "indirect_hausnetz_input")
    node = lock["nodes"]["hausnetz"]
    rev = revision(node["locked"]["rev"])
    for key in ("locked", "original"):
        require(node[key]["type"] == "git" and node[key]["rev"] == rev
                and node[key]["url"] == "ssh://git@github.com/inspr-at/hausnetz",
                "hausnetz_lock_origin")
    require(re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", node["locked"]["narHash"]),
            "hausnetz_nar_hash")
    for field in ("lastModified", "revCount"):
        require(type(node["locked"][field]) is int and node["locked"][field] >= 0,
                "hausnetz_lock_metadata")
    return rev, lock


def mask_lock(text):
    """Mask only approved leaf values, preserving every other byte of JSON."""
    allowed = {("nodes", "hausnetz", "locked", k)
               for k in ("rev", "narHash", "lastModified", "revCount")}
    allowed.add(("nodes", "hausnetz", "original", "rev"))
    decoder = json.JSONDecoder()
    spans = []

    def scan(index, path):
        while text[index].isspace():
            index += 1
        start = index
        if text[index] == "{":
            index += 1
            while True:
                while text[index].isspace():
                    index += 1
                if text[index] == "}":
                    index += 1
                    break
                key, index = decoder.raw_decode(text, index)
                while text[index].isspace():
                    index += 1
                require(text[index] == ":", "invalid_lock_json")
                index = scan(index + 1, path + (key,))
                while text[index].isspace():
                    index += 1
                if text[index] == ",":
                    index += 1
                else:
                    require(text[index] == "}", "invalid_lock_json")
        else:
            _, index = decoder.raw_decode(text, index)
        if path in allowed:
            spans.append((start, index))
        return index

    scan(0, ())
    for start, end in reversed(spans):
        text = text[:start] + '"<pin>"' + text[end:]
    return text


def mask_flake(text, expected):
    lines = text.splitlines(keepends=True)
    blocks = [i for i, line in enumerate(lines) if re.fullmatch(r" *hausnetz = \{\n", line)]
    require(len(blocks) == 1, "hausnetz_flake_block")
    block = blocks[0]
    start = block
    while start and lines[start - 1].lstrip().startswith("#"):
        start -= 1
    url = block + 1
    while url < len(lines) and lines[url].lstrip().startswith("#"):
        url += 1
    require(url < len(lines) and re.fullmatch(
        r' *url = "git\+ssh://git@github.com/inspr-at/hausnetz\?rev=' + expected + r'";\n',
        lines[url]), "hausnetz_flake_url")
    return "".join(lines[:start]) + lines[block] + "<url>\n" + "".join(lines[url + 1:])


def mask_doc(text, rev):
    pattern = (r"(?m)^The private flake input is pinned to `" + rev + r"`\n"
               r"\(`v[0-9.]+`, HNET pin [0-9]+, release sequence [0-9]+; OPS-[0-9]+\)\.$")
    require(len(re.findall(pattern, text)) == 1, "runbook_pin_lines")
    return re.sub(pattern, "<hausnetz-pin>", text)


def mask_test(text, rev, lock):
    node = lock["nodes"]["hausnetz"]["locked"]
    patterns = [r"(?m)^pin = '" + rev + r"'  # HNET pin [0-9]+ \(v[0-9.]+\); repo in inspr-at$"]
    for key in ("narHash", "lastModified", "revCount"):
        literal = "'" + node[key] + "'" if isinstance(node[key], str) else str(node[key])
        patterns.append(r"(?m)^assert node\['locked'\]\['" + key + r"'\] == "
                        + re.escape(literal) + r"(?:  # [^\n]*)?$")
    for index, pattern in enumerate(patterns):
        require(len(re.findall(pattern, text)) == 1, "test_pin_lines")
        text = re.sub(pattern, "<pin-" + str(index) + ">", text)
    return text


def gate_g1(repo, old, new):
    revision(old)
    revision(new)
    git(repo, "merge-base", "--is-ancestor", old, new)
    changes = git(repo, "diff", "--name-status", "--no-renames", old, new).splitlines()
    allowed = {"flake.nix", "flake.lock", "hosts/hsb0/docs/RUNBOOK.md", "tests/T99-hausnetz-hsb0.sh"}
    paths = []
    for line in changes:
        parts = line.split("\t")
        require(len(parts) == 2 and parts[0] == "M" and parts[1] in allowed, "G1_extra_change")
        require(tree_mode(repo, old, parts[1]) == tree_mode(repo, new, parts[1]), "G1_mode_changed")
        paths.append(parts[1])
    require({"flake.nix", "flake.lock"}.issubset(paths), "G1_not_a_pin_bump")
    a_text, b_text = (blob(repo, rev, "flake.lock") for rev in (old, new))
    a, a_lock = lock_pin(a_text)
    b, b_lock = lock_pin(b_text)
    require(a != b, "G1_unchanged_hausnetz")
    require(mask_lock(a_text) == mask_lock(b_text), "G1_lock_scope")
    require(mask_flake(blob(repo, old, "flake.nix"), a)
            == mask_flake(blob(repo, new, "flake.nix"), b), "G1_flake_scope")
    for path in paths:
        if path.endswith("RUNBOOK.md"):
            require(mask_doc(blob(repo, old, path), a) == mask_doc(blob(repo, new, path), b),
                    "G1_runbook_scope")
        if path.endswith("T99-hausnetz-hsb0.sh"):
            require(mask_test(blob(repo, old, path), a, a_lock)
                    == mask_test(blob(repo, new, path), b, b_lock), "G1_test_scope")
    return a, b


def prepare_result(stdout, returncode, expected, nar_hash, running):
    """The entire HNET-570 stdout contract lives here; schema drift is manual."""
    value = strict_json(stdout)  # rejects extra output and duplicate JSON keys
    fields = {"rev", "narHash", "version", "persisted_ok", "manifest_changed",
              "manifest_sha256", "running_manifest_sha256", "changed_paths",
              "changed_paths_total", "checker_rev", "problems"}
    try:
        require(isinstance(value, dict) and set(value) == fields, "G2_prepare_schema")
        require(isinstance(value["problems"], list)
                and all(isinstance(p, str) for p in value["problems"]), "G2_prepare_schema")
        paths = value["changed_paths"]
        require(isinstance(paths, list) and len(paths) <= 100
                and all(isinstance(p, str) for p in paths) and paths == sorted(paths)
                and type(value["changed_paths_total"]) is int
                and value["changed_paths_total"] >= -1, "G2_prepare_schema")
        if returncode != 0:
            raise Manual("G2_prepare_exit_" + str(returncode))
        require(type(value["persisted_ok"]) is bool and type(value["manifest_changed"]) is bool,
                "G2_prepare_schema")
        coordinate(value["version"])
        digest(value["manifest_sha256"])
        digest(value["running_manifest_sha256"])
        require(returncode == 0 and value["persisted_ok"] is True
                and value["manifest_changed"] is False and not value["problems"]
                and value["changed_paths_total"] == 0 and not paths
                and value["checker_rev"] == running
                and value["rev"] == expected and value["narHash"] == nar_hash
                and value["manifest_sha256"] == value["running_manifest_sha256"], "G2_prepare_unsafe")
    except Manual as exc:
        # Preserve well-formed diagnostics even when the rest of the schema
        # drifts or the checker reports manual/bad usage.
        if isinstance(value, dict):
            for name in ("problems", "changed_paths"):
                items = value.get(name)
                if isinstance(items, list):
                    setattr(exc, name, diagnostics(items))
        raise
    return value


def gate_g2(repo, old, new, nar_hash):
    require(not git(repo, "status", "--porcelain"), "G2_dirty_clone")
    try:
        git(repo, "merge-base", "--is-ancestor", old, new)
    except Manual as exc:
        raise Manual("G2_non_descendant") from exc
    # The running release supplies the checker; the candidate cannot grade itself.
    git(repo, "checkout", "--quiet", "--detach", old)
    try:
        path = str(Path(repo).resolve())
        require(Path(repo).is_absolute() and all(c.isprintable() for c in path), "G2_checker_path")
        revision(old)
        checker = "git+file://" + quote(path, safe="/") + "?rev=" + old + "#cd-prepare"
        result = subprocess.run(["nix", "run", "--offline", "--no-write-lock-file", checker, "--",
                                 "--repo", str(repo), "--rev", new, "--running", old],
                                capture_output=True, timeout=600, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Manual("G2_prepare_unavailable_or_timeout") from exc
    return prepare_result(result.stdout, result.returncode, new, nar_hash, old)


def gate_g4(repo, old, new):
    git(repo, "diff", "--quiet", "--no-ext-diff", "--no-textconv", old, new,
        "--", "nix/", "flake.nix", "flake.lock")


def gate_closures(text, old, new):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    require(all(char == "\n" or char.isprintable() for char in text),
            "G3_escaped_closure_output")
    seen = set()
    for line in text.splitlines():
        if not line.strip() or line == old + " → " + new + ":":
            continue
        match = re.fullmatch(r"(?:  )?([A-Za-z0-9_.+-]+): (.+)", line)
        require(match is not None, "G3_unrecognized_closure_output")
        name, change = match.groups()
        require(name in {"hausnetz", "etc", "etc-json", "etc-pharos-deployment-evidence.json",
                         "pharos-deployment-evidence"}
                and name not in seen, "G3_extra_closure")
        if name == "hausnetz":
            require(" → " in change, "G3_hausnetz_not_replaced")
            before, after = change.split(" → ", 1)
            require(before != after.split(", ", 1)[0] and "∅" not in before + after,
                    "G3_hausnetz_not_replaced")
        seen.add(name)
    require("hausnetz" in seen, "G3_no_hausnetz_change")


def gate_units(text):
    allowed = {"stop": {"hausnetz.service", "polkit.service"},
               "start": {"hausnetz.service", "polkit.service"},
               "restart": {"hausnetz.service", "polkit.service"},
               "reload": {"dbus-broker.service"}}
    chatter = {"dry activating the configuration...", "would activate the configuration...",
               "would run sysinit-reactivation", "setting up /etc..."}
    actions = {}
    for line in text.splitlines():
        if not line.strip() or line in chatter:
            continue
        match = re.fullmatch(r"would (stop|start|restart|reload) the following units: (.+)", line)
        require(match is not None, "G3_unrecognized_activation_output")
        action, names = match.groups()
        units = names.split(", ")
        require(action not in actions and all(unit in allowed[action] for unit in units),
                "G3_extra_unit")
        actions[action] = units
    require("hausnetz.service" in sum(actions.values(), []), "G3_no_hausnetz_activation")


def parse_export(data):
    require(0 < len(data) <= 256 * 1024 * 1024, "backup_empty_or_oversized")
    if data.startswith(b"PK"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                files = [entry for entry in archive.infolist() if not entry.is_dir()]
                require(files and 0 < sum(e.file_size for e in files) <= 256 * 1024 * 1024,
                        "backup_invalid_archive")
                require(archive.testzip() is None, "backup_corrupt_archive")
                for entry in files:
                    if entry.filename.endswith(".json"):
                        strict_json(archive.read(entry))
        except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as exc:
            raise Manual("backup_invalid_archive") from exc
        return "zip", hashlib.sha256(data).hexdigest()
    value = strict_json(data)
    require(isinstance(value, (dict, list)) and value, "backup_invalid_json")
    return "json", hashlib.sha256(data).hexdigest()
