#!/usr/bin/env bash
# PIXD-103: hsb1's digest-pinned edge lane must remain shadow-only.
set -euo pipefail

# macOS bash 3.2 can falsely pass failed bare [[ ]] assertions (see T08).
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: run under bash 5: nix run nixpkgs#bash -- %s\n' "${0##*/}" "$0" >&2
  exit 2
fi

# An alternate repo root lets must-fail checks use isolated source copies.
repo_root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
python3 - "$repo_root" <<'PY'
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
host = repo / "hosts/hsb1"
compose_path = host / "docker/compose-spec.nix"
compose = compose_path.read_text()


def require(condition, message):
    if not condition:
        raise SystemExit(f"T120 failed: {message}")


# Evaluate only the authored service and seed, never a NixOS system build or
# any encrypted env file. Labels are checked as source below, without hashing
# secret artifacts. The seed's only used lib helper quotes a plain image name.
expression = r'''
let
  service = (import @COMPOSE@).services.pixdcon2-edge;
  host = import @HOST@ {
    pkgs = {};
    inputs = {};
    lib.escapeShellArg = value: "'" + value + "'";
    config = {
      virtualisation.docker.package = "/test/docker";
      nixcfg.composeStack.spec.services.pixdcon2-edge.image = service.image;
    };
  };
in {
  service = builtins.removeAttrs service [ "labels" ];
  seed = host.systemd.services.pixdcon2-edge-seed;
  extraAfter = host.nixcfg.composeStack.extraAfter;
  tmpfiles = host.systemd.tmpfiles.rules;
}
'''.replace("@COMPOSE@", str(compose_path)).replace("@HOST@", str(host / "configuration.nix"))
contract = json.loads(subprocess.check_output(
    ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression], text=True
))
service = contract["service"]
env = dict(item.split("=", 1) for item in service["environment"])
for key, value in {
    "TZ": "Europe/Vienna",
    "MQTT_PORT": "1883",
    "LOG_LEVEL": "info",
    "PIXDCON_CONFIG_PATH": "/data/config.json",
    "WEB_PORT": "8082",
    "PIXDCON2_INSTANCE": "pixdcon2-edge",
    "PIXDCON2_FORCE_SHADOW": "1",
}.items():
    require(env.get(key) == value, f"{key} must be {value}")
require(len(env) == len(service["environment"]), "duplicate environment keys")
require(service["container_name"] == "pixdcon2-edge", "edge container name")
require(service["network_mode"] == "host", "host networking")
require(service["restart"] == "unless-stopped", "restart policy")
require(service["env_file"] == ["/run/agenix/hsb1-pixdcon-env"], "shared v1 env file")

data = "/home/mba/docker/mounts/pixdcon2-edge:/data"
scenes = "/home/mba/docker/mounts/pixdcon/scenes:/data/scenes:ro"
generated = "/home/mba/docker/mounts/pixdcon/generated-scenes:/data/generated-scenes:ro"
images = "/home/mba/docker/mounts/funkeykid/images:/app/assets/pixoo/funkeykid:ro"
require(set(service["volumes"]) == {data, scenes, generated, images},
        "/data must be a directory mount and scenes/generated-scenes/images must be read-only")
require(len(service["volumes"]) == 4, "unexpected duplicate mounts")
require(re.fullmatch(r"ghcr\.io/markus-barta/pixdcon2:[^@]+@sha256:[0-9a-f]{64}",
                     service["image"]), "edge image must be pinned by @sha256:")
require(len(re.findall(r"\bpixdcon2EdgeImage\s*=", compose)) == 1, "one image pin binding")


def service_source(name):
    match = re.search(r"^    " + re.escape(name) + r" = \{\n(.*?)^    \};", compose, re.M | re.S)
    require(match is not None, f"missing {name} service source")
    return match.group(1)


edge_source = service_source("pixdcon2-edge")
require("watchtower" not in edge_source.lower(), "edge must have no watchtower labels")
hash_label = '("pixdcon.env-rev=" + builtins.hashFile "sha256" ../../../secrets/hsb1-pixdcon-env.age)'
for name in ("pixdcon", "pixdcon2-edge"):
    require(hash_label in service_source(name), f"{name} must use the shared env revision label")
require("image = pixdcon2EdgeImage;" in edge_source, "service must use the single image binding")

seed = contract["seed"]
require(seed["serviceConfig"]["Type"] == "oneshot", "seed must be a oneshot")
require(seed["unitConfig"]["ConditionPathExists"] ==
        "!/home/mba/docker/mounts/pixdcon2-edge/config.json", "seed must skip existing config.json")
for key in ("before", "wantedBy"):
    require("compose-hsb1.service" in seed[key], f"seed {key} compose-hsb1.service")
for dependency in ("docker.service", "systemd-tmpfiles-setup.service"):
    require(dependency in seed["after"], f"seed must run after {dependency}")
require("pixdcon2-edge-seed.service" in contract["extraAfter"],
        "composeStack must Want the seed via extraAfter")
require(not seed.get("requires"), "seed must not require dependencies")
require("d /home/mba/docker/mounts/pixdcon2-edge 0755 mba users -" in contract["tmpfiles"],
        "edge data directory tmpfiles ownership/mode")

words = shlex.split(seed["script"].replace("\\\n", ""))
require(words[:3] == ["/test/docker/bin/docker", "run", "--rm"], "seed must use docker run --rm")
require(words.count(service["image"]) == 1, "seed and service must use the same image")
require("type=bind,src=/home/mba/docker/mounts/pixdcon/config.json,dst=/seed/v1-config.json,readonly"
        in words, "seed must mount v1 config read-only without creating a missing source")
require(all(mount in words for mount in (data, scenes, generated)), "seed data and read-only scene mounts")
require(words[-8:] == ["node", "src/config/migrate-v1.js", "/seed/v1-config.json", "/data",
                       "--output", "shadow", "--status-base-topic", "home/hsb1/pixdcon2-edge"],
        "seed must migrate to shadow output with an isolated status base topic")
print("T120 passed: pixdcon2-edge is pinned, shadow-only, read-only for v1 data and seeded best-effort")
PY
