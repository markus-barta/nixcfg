#!/usr/bin/env bash
# OPS-180 / OPS-182 headscale DERP-map contract.
#
# 2026-08-21: headscale 0.25.1 replaced the DERP map with an EMPTY one when the
# scheduled derp.urls refresh failed (netcup outage -> fleet-wide "no relay").
# A vendored snapshot wired via derp.paths bridged the gap until 0.27 (OPS-180).
#
# From 0.27 the load order flips — URLs first, then paths OVERWRITE them — and a
# failed refresh keeps the previous map (#2741). A snapshot would now shadow live
# data, so this test pins the opposite contract: image >= 0.27, no fallback file,
# derp.paths empty, derp.urls still the live source.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfgdir="${repo}/hosts/csb0/docker/headscale/config"
config="${cfgdir}/config.yaml"
compose="${repo}/hosts/csb0/docker/compose-spec.nix"

image_tag="$(sed -nE 's/^ *image = "headscale\/headscale:([0-9]+\.[0-9]+)[^"]*";.*/\1/p' "${compose}" | head -1)"
[ -n "${image_tag}" ] || {
  echo "T43: headscale image tag not found in compose-spec.nix" >&2
  exit 1
}
major="${image_tag%%.*}"
minor="${image_tag#*.}"
if [ "${major}" -eq 0 ] && [ "${minor}" -lt 27 ]; then
  echo "T43: headscale ${image_tag} < 0.27 needs the OPS-180 derp.paths fallback again" >&2
  exit 1
fi
if [ -e "${cfgdir}/derp-fallback.yaml" ]; then
  echo "T43: derp-fallback.yaml must not exist on headscale >= 0.27 (paths overwrite the live map)" >&2
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "${config}" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as fh:
    derp = yaml.safe_load(fh)["derp"]
assert derp["paths"] == [], f"derp.paths must be empty on >= 0.27, got {derp['paths']}"
assert derp["urls"], "derp.urls must stay populated (live source)"
assert derp["auto_update_enabled"] is True
print("T43: >= 0.27 contract ok — no fallback, live derp.urls")
PY
echo "T43 ok"
