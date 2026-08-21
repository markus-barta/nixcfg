#!/usr/bin/env bash
# OPS-180 headscale DERP-map fallback contract.
#
# headscale <=0.26 replaces the DERP map with an EMPTY one when the scheduled
# derp.urls refresh fails (2026-08-21: netcup outage -> fleet-wide "no relay").
# hosts/csb0/docker/headscale/config/derp-fallback.yaml is a vendored snapshot
# wired via derp.paths so a failed fetch can no longer empty the map.
#
# From headscale 0.27 the load order flips (URLs first, paths overwrite) and the
# refresh keeps the old map on failure, so the fallback MUST go when the image
# moves to 0.27 (OPS-182). This test fails loudly in that case.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfgdir="${repo}/hosts/csb0/docker/headscale/config"
config="${cfgdir}/config.yaml"
fallback="${cfgdir}/derp-fallback.yaml"
compose="${repo}/hosts/csb0/docker/compose-spec.nix"

# Wiring: the whole config dir is bind-mounted, so the container path must match.
grep -Fq '"./headscale/config:/etc/headscale:ro"' "${compose}"
grep -Fq 'REMOVE AT HEADSCALE 0.27' "${fallback}"
grep -Fq 'https://controlplane.tailscale.com/derpmap/default' "${fallback}"

# Removal guard: headscale >= 0.27 must not carry the fallback.
image_tag="$(sed -nE 's/^ *image = "headscale\/headscale:([0-9]+\.[0-9]+)[^"]*";.*/\1/p' "${compose}" | head -1)"
[ -n "${image_tag}" ] || {
  echo "T43: headscale image tag not found in compose-spec.nix" >&2
  exit 1
}
major="${image_tag%%.*}"
minor="${image_tag#*.}"
if [ "${major}" -gt 0 ] || [ "${minor}" -ge 27 ]; then
  echo "T43: headscale ${image_tag} >= 0.27 — remove derp-fallback.yaml + derp.paths (OPS-182)" >&2
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "${config}" "${fallback}" <<'PY'
import sys
import yaml

config_path, fallback_path = sys.argv[1], sys.argv[2]
with open(config_path) as fh:
    config = yaml.safe_load(fh)
derp = config["derp"]
assert derp["paths"] == ["/etc/headscale/derp-fallback.yaml"], derp["paths"]
assert derp["urls"], "derp.urls must stay populated: the snapshot is a fallback, not the source"
assert derp["auto_update_enabled"] is True

with open(fallback_path) as fh:
    fb = yaml.safe_load(fh)
regions = fb["regions"]
assert isinstance(regions, dict) and len(regions) >= 20, f"only {len(regions)} regions"
for rid, region in regions.items():
    assert isinstance(rid, int), f"region key {rid!r} must be an int"
    assert region["regionid"] == rid, f"region {rid}: regionid {region['regionid']}"
    assert region["regioncode"] and region["regionname"], f"region {rid}: code/name"
    nodes = region["nodes"]
    assert nodes, f"region {rid}: no nodes"
    for node in nodes:
        assert node["regionid"] == rid, f"region {rid}: node {node.get('name')} regionid"
        assert node["name"] and node["hostname"], f"region {rid}: node name/hostname"
print(f"T43: fallback ok — {len(regions)} regions, {sum(len(r['nodes']) for r in regions.values())} nodes")
PY
echo "T43 ok"
