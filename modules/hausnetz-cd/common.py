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
import zipfile


class Manual(Exception):
    """A value-free reason safe to put in deployment evidence."""


REV = re.compile(r"[0-9a-f]{40}")
EVIDENCE_SCHEMA = "inspr.pharos.nix-deployment-evidence.v1"
RESULT_SCHEMA = "inspr.pharos.guarded-deploy-result.v1"
TERMINAL = {"manual", "dry-run", "succeeded", "failed", "rollback_failed", "skipped"}


def require(condition, reason):
    if not condition:
        raise Manual(reason)


def revision(value):
    require(isinstance(value, str) and REV.fullmatch(value), "invalid_revision")
    return value


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def run(args, *, timeout=60, data=None, binary=False):
    # Do not return command lines, remote diagnostics, API bodies or exceptions
    # to logs: private git diagnostics can contain credential-bearing URLs.
    try:
        result = subprocess.run(
            [str(a) for a in args], input=data, capture_output=True,
            text=not binary, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Manual("command_unavailable_or_timeout") from exc
    require(result.returncode == 0, "command_failed")
    return result.stdout


def http_get(url, timeout):
    response = run(["curl", "--disable", "--fail", "--silent", "--noproxy", "*",
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
    return run(["git", "-C", repo, *args])


def cache_repo(path, url, *revs):
    path = Path(path)
    if not path.exists():
        run(["git", "clone", "--bare", "--quiet", url, path], timeout=90)
    require(git(path, "config", "--get", "remote.origin.url").strip() == url,
            "cache_origin_mismatch")
    git(path, "fetch", "--quiet", "origin", "refs/heads/main:refs/heads/main")
    for rev in revs:
        revision(rev)
        try:
            git(path, "cat-file", "-e", rev + "^{commit}")
        except Manual:
            git(path, "fetch", "--quiet", "origin", rev)
    return path


def blob(repo, rev, path):
    entry = git(repo, "ls-tree", rev, "--", path).split()
    require(len(entry) == 4 and entry[0:2] == ["100644", "blob"], "nonregular_gate_input")
    return run(["git", "-C", repo, "show", rev + ":" + path], binary=True).decode("utf-8")


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


def gate_g2(repo, old, new, path):
    require(isinstance(path, str) and path and not path.startswith("/")
            and all(p not in ("", ".", "..") for p in path.split("/")), "G2_manifest_unset_or_invalid")
    a, b = (blob(repo, rev, path) for rev in (old, new))
    require(a.strip() and a == b, "G2_manifest_changed_or_empty")


def gate_closures(text, old, new):
    require("\x1b" not in text, "G3_escaped_closure_output")
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
