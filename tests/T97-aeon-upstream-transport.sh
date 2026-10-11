#!/usr/bin/env bash
# OPS-308: evaluate the Aeon transport binding and its mounted file-provider config.
# Pure evaluation only; no NixOS build, Docker, or host access.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$repo_root" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])


def read_json(command):
    return json.loads(subprocess.check_output(command, cwd=root, text=True))


compose = read_json([
    "nix-instantiate", "--eval", "--strict", "--json", "--expr", """
      let spec = import ./hosts/csb1/docker/compose-spec.nix;
      in {
        transportLabels = builtins.mapAttrs (_: service:
          builtins.filter (label:
            builtins.match "traefik[.]http[.]services[.].*[.]loadbalancer[.]serversTransport=.*" label != null
          ) (service.labels or [])
        ) spec.services;
        traefikVolumes = spec.services.traefik.volumes;
        fileServices = (import ./hosts/csb1/ppm-aeon-redirect-routing.nix { }).http.services;
      }
    """,
])
binding = "traefik.http.services.aeon.loadbalancer.serversTransport=aeon-noreuse@file"
assert compose["transportLabels"]["aeon"] == [binding], "Aeon must bind aeon-noreuse@file"
consumers = [
    name for name, labels in compose["transportLabels"].items()
    if any(label.endswith("=aeon-noreuse@file") for label in labels)
]
assert consumers == ["aeon"], "The no-reuse transport must remain scoped to Aeon"
file_services = compose["fileServices"]
assert file_services["ops231-aeon"]["loadBalancer"]["servers"] == [{"url": "http://aeon:8080"}], (
    "The classic API route must still target Aeon"
)
for name, service in file_services.items():
    balancer = service.get("loadBalancer", {})
    targets_aeon = any(server.get("url") == "http://aeon:8080" for server in balancer.get("servers", []))
    uses_noreuse = balancer.get("serversTransport") == "aeon-noreuse"
    assert targets_aeon == uses_noreuse, (
        f"File service {name}: every Aeon upstream must bind aeon-noreuse, scoped to Aeon"
    )
assert "./traefik/dynamic.yml:/etc/traefik/dynamic/dynamic.yml" in compose["traefikVolumes"], (
    "Traefik must mount the dynamic file defining Aeon's transport"
)

traefik = root / "hosts/csb1/docker/traefik"
transports = read_json(["yq", "-o=json", ".http.serversTransports", str(traefik / "dynamic.yml")])
assert isinstance(transports, dict), "The HTTP serversTransports section must exist"
assert transports.get("aeon-noreuse") == {"maxIdleConnsPerHost": -1}, (
    "Aeon must disable idle connection reuse and keep every other transport setting at defaults"
)
assert type(transports["aeon-noreuse"]["maxIdleConnsPerHost"]) is int, (
    "maxIdleConnsPerHost must be a YAML integer"
)
provider = read_json(["yq", "-o=json", ".providers.file", str(traefik / "static.yml")])
assert provider.get("directory") == "/etc/traefik/dynamic" and provider.get("watch") is True, (
    "Traefik's file provider must watch the mounted dynamic directory"
)
print("OPS-308 Aeon upstream transport contract OK (pure evaluation; no host access)")
PY
