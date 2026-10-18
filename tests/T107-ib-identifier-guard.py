#!/usr/bin/env python3
"""OPS-317/369: keep broker identifiers out of public source and fixtures."""

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = re.compile(
    r"(?<![A-Za-z0-9])(?:DU|DF|U)[A-Z]?[0-9]{5,8}(?![A-Za-z0-9])",
    re.IGNORECASE,
)
FAKE_ACCOUNTS = frozenset({"DU0000001", "DU0000002", "U0000001"})
IDENTITY_ASSIGNMENT = re.compile(
    r"(?<![A-Za-z0-9_])(?:TWS_USERID|IB_DESK_ACCOUNT)\s*=\s*"
    r"(?:[\"'][^\s;,)\]}]|[^\"'\s;,)\]}])",
    re.IGNORECASE,
)
HEX_CONSTANT = re.compile(r"(?<![A-Za-z0-9])[0-9a-f]{64}(?![A-Za-z0-9])", re.IGNORECASE)
UNICODE_ESCAPE = re.compile(r"\\u[0-9a-fA-F]{4}")
STORAGE_LOCATOR = re.compile(
    r"sftp:u[0-9]+(?:-sub[0-9]+)?@u[0-9]+\.your-storagebox\.de:(?:[0-9]+)?/"
    r"|^u[0-9]+\.your-storagebox\.de(?=[,\s])"
    r"|^\[u[0-9]+\.your-storagebox\.de\]:[0-9]+(?=[,\s])"
)


def unexpected_lines(text, name=""):
    def source_line(line):
        # These syntactic contexts are not broker identities. Keep the account
        # allowlist fake-only; do not exempt files or unrelated text on a line.
        if Path(name).suffix in {".html", ".js", ".mjs", ".json"}:
            line = UNICODE_ESCAPE.sub("<unicode-escape>", line)
        if Path(name).name in {"compose-spec.nix", "ssh_known_hosts"}:
            line = STORAGE_LOCATOR.sub("<storage-locator>", line)
        return line

    return [
        number
        for number, line in enumerate(text.splitlines(), 1)
        if any(match[0].upper() not in FAKE_ACCOUNTS for match in ACCOUNT.finditer(source_line(line)))
    ]


def structural_violations(name, text):
    path = Path(name)
    rules = []
    if path.suffix in {".nix", ".yml", ".yaml"}:
        rules.append((IDENTITY_ASSIGNMENT, "public identity assignment"))
    # No test-file exemptions: existing tests need no literal hash constants.
    if path.parent == Path("modules/paper-desk-executor") and path.suffix == ".mjs":
        rules.append((HEX_CONSTANT, "64-hex executor constant"))
    return [
        (number, reason)
        for number, line in enumerate(text.splitlines(), 1)
        for pattern, reason in rules
        if pattern.search(line)
    ]


def self_test():
    # Exercise detection without embedding a forbidden identifier in the test.
    assert unexpected_lines(" ".join(FAKE_ACCOUNTS)) == []
    assert unexpected_lines(" ".join(FAKE_ACCOUNTS).lower()) == []
    for prefix in ("DU", "DF", "U", "DUR"):
        candidate = prefix + "12345678"
        for value in (candidate, candidate.lower()):
            assert unexpected_lines("safe\n" + value) == [2]
            assert unexpected_lines("safe\nacct_" + value + "_suffix") == [2]
            for character in ("x", "X", "0"):
                assert unexpected_lines(character + value) == []
                assert unexpected_lines(value + character) == []

    for suffix in (".nix", ".yml", ".yaml"):
        name = "fixture" + suffix
        for key in ("TWS_USERID", "IB_DESK_ACCOUNT"):
            for value in (key, key.lower()):
                assert structural_violations(name, 'safe\n"' + value + '=synthetic"') == [
                    (2, "public identity assignment")
                ]
                assert structural_violations(name, value + " = synthetic") == [
                    (1, "public identity assignment")
                ]
                assert structural_violations(name, "OTHER_" + value + "=synthetic") == []
        assert structural_violations(name, "env_file = [ runtime.path ];") == []
        assert structural_violations(name, "TWS_USERID and IB_DESK_ACCOUNT") == []
        assert structural_violations(name, 'lib.hasPrefix "IB_DESK_ACCOUNT=" item') == []
        assert structural_violations(name, 'IB_DESK_ACCOUNT = "synthetic";') == [
            (1, "public identity assignment")
        ]

    candidate = "U" + "12345678"
    for name in ("fixture.html", "fixture.js", "fixture.mjs", "fixture.json"):
        assert unexpected_lines(r"\u0030" + "12", name) == []
        assert unexpected_lines(r"\u0030 " + candidate, name) == [1]
    assert unexpected_lines(r"\u0030" + "12", "fixture.txt") == [1]
    locator = "sftp:u" + "12345678-sub1@u" + "12345678.your-storagebox.de:/"
    host = "u" + "12345678.your-storagebox.de"
    for name in ("compose-spec.nix", "ssh_known_hosts"):
        assert unexpected_lines(locator, name) == []
        assert unexpected_lines(locator.replace(":/", ":23/fixture"), name) == []
        assert unexpected_lines(host + " ssh-ed25519 synthetic", name) == []
        assert unexpected_lines("[" + host + "]:23 ssh-ed25519 synthetic", name) == []
        assert unexpected_lines(locator + " " + candidate, name) == [1]
        assert unexpected_lines(candidate, name) == [1]
    assert unexpected_lines(locator, "fixture.txt") == [1]

    for name in ("ib.mjs", "executor.test.mjs"):
        name = "modules/paper-desk-executor/" + name
        for character in ("a", "A", "0"):
            candidate = character * 64
            assert structural_violations(name, 'safe\nconst PIN = "' + candidate + '";') == [
                (2, "64-hex executor constant")
            ]
            assert structural_violations(name, character * 63) == []
            assert structural_violations(name, character * 65) == []
    assert structural_violations("other/ib.mjs", "a" * 64) == []


def main():
    self_test()

    # Include new source files before staging. Git metadata, ignored local state
    # and submodule internals are not public source in this repository.
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).decode().split("\0")
    failures = []
    for name in sorted(set(paths) - {""}):
        path = ROOT / name
        # Do not open encrypted/config secret files, even outside secrets/.
        if name.startswith("secrets/") or path.name == "flake.lock":
            continue
        if path.suffix in {".age", ".env", ".gpg"} or path.is_symlink() or not path.is_file():
            continue
        text = path.read_bytes().decode("utf-8", errors="replace")
        failures.extend(f"{name}:{line}: unexpected account-shaped identifier" for line in unexpected_lines(text, name))
        failures.extend(f"{name}:{line}: {reason}" for line, reason in structural_violations(name, text))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("T107 passed: unexpected account-shaped identifiers = 0; public identity assignments = 0; executor 64-hex constants = 0 (self-tests passed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
