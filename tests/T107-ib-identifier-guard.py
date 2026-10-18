#!/usr/bin/env python3
"""OPS-317/369: keep broker identifiers out of public source and fixtures."""

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = re.compile(r"\b(?:DU|DF|U)[A-Z]?[0-9]{5,8}\b")
FAKE_ACCOUNTS = frozenset({"DU0000001", "DU0000002", "U0000001"})


def unexpected_lines(text):
    return [
        number
        for number, line in enumerate(text.splitlines(), 1)
        if any(match[0] not in FAKE_ACCOUNTS for match in ACCOUNT.finditer(line))
    ]


def main():
    # Exercise detection without embedding a forbidden identifier in the test.
    assert unexpected_lines(" ".join(FAKE_ACCOUNTS)) == []
    for prefix in ("DU", "DF", "U", "DUR"):
        candidate = prefix + "1234567"
        assert unexpected_lines("safe\n" + candidate) == [2]
        assert unexpected_lines("x" + candidate + "x") == []

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
        failures.extend(f"{name}:{line}: unexpected account-shaped identifier" for line in unexpected_lines(text))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("T107 passed: unexpected account-shaped identifiers = 0 (fake allowlist only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
