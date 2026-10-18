#!/usr/bin/env python3
"""OPS-338: static config controls csb1 Traefik recreation, offline and eval-only."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "hosts/csb1/docker/traefik/static.yml"
LABEL = "ops.static-config-sha256="


def read_json(command):
    result = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, timeout=30, check=False
    )
    # Do not print evaluated configuration or subprocess output on failure.
    assert result.returncode == 0, f"{command[0]}: offline evaluation failed"
    return json.loads(result.stdout)


def main():
    contract = read_json([
        "nix-instantiate", "--eval", "--strict", "--json", "--expr", """
        let
          host = import ./hosts/csb1/configuration.nix {
            config = {}; lib = {}; pkgs = {}; inputs = {};
          };
          traefik = host.nixcfg.composeStack.spec.services.traefik;
        in {
          inherit (host.nixcfg.composeStack) postRecreate;
          inherit (traefik) labels volumes command env_file;
          entrypoint = traefik.entrypoint or null;
        }
        """,
    ])
    assert contract["postRecreate"] == ["hostdash-auth", "hostdash"], (
        "Traefik must not be force-recreated; retain both HostDash services"
    )
    digest = hashlib.sha256(STATIC.read_bytes()).hexdigest()
    assert [label for label in contract["labels"] if label.startswith(LABEL)] == [LABEL + digest], (
        "Traefik must carry exactly one static-config label matching the tree"
    )

    # Guard the expression as well as its current value: a frozen digest would
    # pass a single evaluation but miss the next static config change.
    source = (ROOT / "hosts/csb1/docker/compose-spec.nix").read_text()
    traefik_source = source.split("    traefik = {", 1)[1].split("\n    };", 1)[0]
    assert '"ops.static-config-sha256=${builtins.hashFile "sha256" ./traefik/static.yml}"' in traefik_source
    hash_calls = re.findall(r"builtins[.]hashFile\s+\"sha256\"\s+([^\s}]+)", traefik_source)
    assert hash_calls == ["./traefik/static.yml"], "Only static config may be file-hashed"
    assert not re.search(r"builtins[.](hashString|readFile)", traefik_source), (
        "Do not indirectly hash ACME state or runtime credentials"
    )
    assert contract["command"] == "--configFile=/etc/traefik/traefik.yml"
    assert contract["entrypoint"] is None, "Re-audit startup files if the entrypoint changes"
    assert contract["env_file"] == ["/run/agenix/traefik-variables"], (
        "Runtime credentials must remain outside the config hash"
    )

    provider = read_json(["yq", "-o=json", ".providers.file", str(STATIC)])
    assert provider == {"directory": "/etc/traefik/dynamic", "watch": True}, (
        "The file provider must watch every mounted dynamic file"
    )
    mounts = {}
    for volume in contract["volumes"]:
        if isinstance(volume, str):
            source, target, *mode = volume.split(":")
        else:
            source, target = volume["source"], volume["target"]
        assert target not in mounts, "Duplicate Traefik mount target"
        mounts[target] = source
    assert mounts.pop("/etc/traefik/traefik.yml") == "./traefik/static.yml"
    for name in ("acme.json", "acme-http.json"):
        assert mounts.pop(f"/etc/traefik/acme/{name}") == f"./traefik/{name}"
        assert f"./traefik/{name}:/etc/traefik/acme/{name}:rw" in contract["volumes"], (
            "ACME state mounts must remain writable and unchanged"
        )
    assert mounts == {
        "/etc/traefik/dynamic/dynamic.yml": "./traefik/dynamic.yml",
        "/etc/traefik/dynamic/inspr-edge.yml": "/run/inspr-edge/dynamic.yml",
        "/etc/traefik/dynamic/inspr-shared-flow.yml": "/run/inspr-shared-flow/dynamic.yml",
    }, "Re-audit new startup mounts or changed dynamic mount coverage"
    assert all(str(PurePosixPath(target).parent) == provider["directory"] for target in mounts)
    print("OPS-338 Traefik recreation contract OK (static hash, watched dynamic files, unhashed ACME)")


if __name__ == "__main__":
    main()
