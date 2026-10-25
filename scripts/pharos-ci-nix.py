#!/usr/bin/env python3
"""Select only flake.lock's public nixpkgs, without evaluating private inputs."""

import json
from pathlib import Path
import re
import subprocess
import time


def print_environment(key, value):
    if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)
            or "\n" in value or "\r" in value):
        raise ValueError("environment output requires a valid key and a single-line value")
    print(f"{key}={value}")


def prepare(lock_path):
    lock = json.loads(Path(lock_path).read_text())
    node = lock["nodes"][lock["nodes"][lock["root"]]["inputs"]["nixpkgs"]]["locked"]
    # Keep cache population public even if an input is accidentally replaced.
    if (node["type"] != "github" or node["owner"].lower() != "nixos"
            or node["repo"] != "nixpkgs"
            or not re.fullmatch(r"[0-9a-f]{40}", node["rev"])
            or not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", node["narHash"])):
        raise ValueError("Pharos CI requires an immutable public nixos/nixpkgs input")
    started = time.monotonic()
    result = json.loads(subprocess.check_output([
        "nix", "store", "prefetch-file", "--json", "--unpack", "--name", "source",
        "--expected-hash", node["narHash"],
        f"https://github.com/nixos/nixpkgs/archive/{node['rev']}.tar.gz",
    ], text=True))
    source = result["storePath"]
    if (result["hash"] != node["narHash"]
            or not re.fullmatch(r"/nix/store/[0-9a-z]{32}-source", source)):
        raise ValueError("public nixpkgs hash or store path does not match the lock")
    # Subsequent nix-shell commands and flake evaluations now reuse one tree.
    print_environment("NIX_PATH", f"nixpkgs={source}")
    print_environment("pharos_public_nixpkgs", node["rev"])
    print_environment("pharos_public_input_seconds", f"{time.monotonic() - started:.3f}")


if __name__ == "__main__":
    prepare("flake.lock")
