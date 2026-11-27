#!/usr/bin/env bash
# OPS-732: evaluate only standalone share settings and Plex volumes; no NixOS
# build, activation scripts, encrypted files or secret-derived compose labels.
set -euo pipefail

# An alternate root supports must-fail checks against isolated source copies.
repo_root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
python3 -B - "$repo_root" <<'PY'
import copy
import json
import posixpath
import subprocess
import sys
from pathlib import Path, PurePosixPath

repo = Path(sys.argv[1]).resolve()
expression = r'''
{ sambaPath, composePath }:
let
  samba = import (builtins.toPath sambaPath) {
    config = {};
    lib.mkDefault = value: value;
    pkgs = {};
  };
in {
  shares = samba.services.samba.settings;
  plexVolumes = (import (builtins.toPath composePath)).services.plex.volumes;
}
'''
result = subprocess.run(
    ["nix-instantiate", "--eval", "--strict", "--json",
     "--argstr", "sambaPath", str(repo / "hosts/hsb1/media-samba.nix"),
     "--argstr", "composePath", str(repo / "hosts/hsb1/docker/compose-spec.nix"),
     "--expr", expression],
    capture_output=True, text=True,
)
if result.returncode:
    raise SystemExit(f"T128 evaluation failed:\n{result.stderr.strip()}")
contract = json.loads(result.stdout)

expected = {
    "valid users": "markus",
    "read only": "no",
    "browseable": "yes",
    "force user": "mba",
    "force group": "users",
    "create mask": "0664",
    "force create mode": "0664",
    "directory mask": "0775",
    "force directory mode": "0775",
    "veto files": (
        "/._*/.DS_Store/.Trashes/.Spotlight-V100/.TemporaryItems/.fseventsd/"
        "Network Trash Folder/Temporary Items/"
    ),
    "delete veto files": "yes",
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check(data):
    shares = data["shares"]
    require("media" in shares and "archive" in shares, "media and archive shares must exist")
    media, archive = shares["media"], shares["archive"]
    require(media.get("path") == "/srv/media", "media path must be /srv/media")
    require(archive.get("path") == "/srv/archive", "archive path must be /srv/archive")
    media_path, archive_path = PurePosixPath(media["path"]), PurePosixPath(archive["path"])
    require(archive_path != media_path and media_path not in archive_path.parents,
            "archive must remain outside /srv/media")
    require({k: v for k, v in media.items() if k != "path"} ==
            {k: v for k, v in archive.items() if k != "path"},
            "media and archive policies must match")
    for name, share in (("media", media), ("archive", archive)):
        for key, value in expected.items():
            require(share.get(key) == value, f"{name}: {key} must be {value}")
        require("vfs objects" not in share, f"{name} must remain plain SMB without vfs objects")
    require("vfs objects" not in shares.get("global", {}), "global vfs objects would affect both shares")

    volumes = data["plexVolumes"]
    require("/srv/media:/media:ro" in volumes, "Plex must retain its existing read-only media mount")
    for volume in volumes:
        if isinstance(volume, str):
            # A string without ':' is an anonymous container volume.
            source = volume.split(":", 1)[0] if ":" in volume else ""
        else:
            require(isinstance(volume, dict), "unrecognized Plex volume syntax")
            source = volume.get("source", "")
        require(isinstance(source, str), "Plex volume source must be a string")
        if not source.startswith("/"):
            continue  # Named/anonymous volumes do not bind a host path.
        source_path = PurePosixPath(posixpath.normpath("/" + source.lstrip("/")))
        require(source_path != archive_path and source_path not in archive_path.parents
                and archive_path not in source_path.parents,
                f"Plex volume exposes archive data: {source}")


try:
    check(contract)
except AssertionError as error:
    raise SystemExit(f"T128 failed: {error}")

# Exercise the same checker with bad evaluated inputs, including simultaneous
# policy drift, inherited VFS, short/long bind syntax and normalized traversal.
mutants = {}
for key in expected:
    mutant = copy.deepcopy(contract)
    mutant["shares"]["archive"][key] = "mutated"
    mutants[f"archive {key}"] = mutant
for name, path in (("wrong path", "/srv/other"), ("nested archive", "/srv/media/archive")):
    mutant = copy.deepcopy(contract)
    mutant["shares"]["archive"]["path"] = path
    mutants[name] = mutant
mutant = copy.deepcopy(contract)
del mutant["shares"]["archive"]
mutants["missing archive"] = mutant
for key, value in (("force user", "nobody"), ("create mask", "0744"), ("vfs objects", "fruit")):
    mutant = copy.deepcopy(contract)
    for name in ("media", "archive"):
        mutant["shares"][name][key] = value
    mutants[f"shared {key}"] = mutant
mutant = copy.deepcopy(contract)
mutant["shares"]["global"]["vfs objects"] = "fruit"
mutants["inherited vfs objects"] = mutant
for source in ("/srv/archive", "/srv/archive/subdir", "/srv", "/", "/srv/media/../archive", "//srv/archive"):
    for syntax in ("short", "long"):
        mutant = copy.deepcopy(contract)
        volume = f"{source}:/backup:ro" if syntax == "short" else {
            "type": "bind", "source": source, "target": "/backup", "read_only": True,
        }
        mutant["plexVolumes"].append(volume)
        mutants[f"Plex {syntax} {source}"] = mutant
for name, mutant in mutants.items():
    try:
        check(mutant)
    except AssertionError:
        continue
    raise SystemExit(f"T128 self-check failed: mutant {name!r} was accepted")

print(f"T128 passed: archive SMB policy matches media, Plex is isolated ({len(mutants)} mutants rejected)")
PY
