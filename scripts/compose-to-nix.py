#!/usr/bin/env python3
"""Mechanically convert a host's docker-compose.yml into a Nix spec — OPS-116/117.

This does the boring 90% of a host migration. It is deliberately dumb: it
preserves types, key order and structure exactly, and makes no judgements. The
interesting 10% — carrying the comments across, and deleting the hand-pinned
`dns:` anchors the module now supplies — is left to a human, because that is
where the review value is.

The output is checked by tests/compose_stack_gate.py, which re-evaluates the
result through Nix and requires it to be semantically identical to the YAML it
came from. So a conversion bug is caught rather than deployed.

Usage:
    nix shell nixpkgs#yq-go -c ./scripts/compose-to-nix.py hosts/hsb1/docker/docker-compose.yml
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

# Nix bare attribute names: letters, digits, _, -, ' and must not start with a
# digit. Anything else (notably keys containing '.', which Nix would read as
# nesting) has to be quoted.
BARE = re.compile(r"^[A-Za-z_][A-Za-z0-9_'-]*$")

# Compose keys the module owns. If the source file still carries them we drop
# them here AND say so, because silently discarding config is how a migration
# loses a setting nobody notices for months.
MODULE_OWNED = ("dns", "dns_search")


def nix_string(value: str) -> str:
    """Emit a Nix double-quoted string.

    `${` must be escaped or Nix treats it as antiquotation — compose files carry
    literal `${VAR}` for its own interpolation, and an unescaped one would either
    fail to parse or, worse, silently interpolate a Nix value.
    """
    out = value.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("${", "\\${")
    out = out.replace("\n", "\\n").replace("\t", "\\t")
    return f'"{out}"'


def nix_key(key: str) -> str:
    return key if BARE.match(key) else nix_string(key)


def emit(value, indent: int = 0) -> str:
    pad = "  " * indent
    inner = "  " * (indent + 1)

    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    if isinstance(value, str):
        return nix_string(value)

    if isinstance(value, list):
        if not value:
            return "[ ]"
        items = "\n".join(f"{inner}{emit(v, indent + 1)}" for v in value)
        return f"[\n{items}\n{pad}]"

    if isinstance(value, dict):
        if not value:
            return "{ }"
        rows = "\n".join(
            f"{inner}{nix_key(str(k))} = {emit(v, indent + 1)};" for k, v in value.items()
        )
        return f"{{\n{rows}\n{pad}}}"

    raise TypeError(f"unconvertible value of type {type(value).__name__}: {value!r}")


def strip_module_owned(spec: dict) -> list[str]:
    """Remove keys the module now supplies. Returns what was dropped, for review."""
    dropped: list[str] = []
    for name, service in (spec.get("services") or {}).items():
        if not isinstance(service, dict):
            continue
        for key in MODULE_OWNED:
            if key in service:
                dropped.append(f"{name}.{key} = {service[key]!r}")
                del service[key]
    # The anchors themselves are top-level extension fields.
    for key in [k for k in spec if k.startswith("x-host-dns")]:
        dropped.append(f"{key} (anchor)")
        del spec[key]
    return dropped


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    raw = subprocess.run(
        ["yq", "-o=json", ".", str(source)], check=True, capture_output=True, text=True
    ).stdout
    spec = json.loads(raw)

    dropped = strip_module_owned(spec)

    project = spec.get("name")
    print(f"# Generated from {source} by scripts/compose-to-nix.py — REVIEW BEFORE USE.", flush=True)
    print("# Comments from the source file are NOT carried across by this tool; re-attach", flush=True)
    print("# them by hand. They hold real incident history.", flush=True)
    if project:
        print(f"# Compose project name: {project} — named volumes depend on it.", flush=True)
    if dropped:
        print("#", flush=True)
        print("# Dropped (now supplied by the composeStack module):", flush=True)
        for item in dropped:
            print(f"#   {item}", flush=True)
    print(flush=True)
    print(emit(spec))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
