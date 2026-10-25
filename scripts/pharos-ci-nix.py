#!/usr/bin/env python3
"""Select only flake.lock's public nixpkgs, without evaluating private inputs."""

import json
import os
from pathlib import Path
import re
import subprocess
import time


def prepare(lock_path, github_env):
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
    with Path(github_env).open("a") as output:
        output.write(f"NIX_PATH=nixpkgs={source}\n")
    print(f"pharos_public_nixpkgs={node['rev']}")
    print(f"pharos_public_input_seconds={time.monotonic() - started:.3f}")


if __name__ == "__main__":
    prepare("flake.lock", os.environ["GITHUB_ENV"])
