#!/usr/bin/env bash
# OPS-327 csb1 Docker image GC contract.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/csb1/docker-image-gc.nix"
script="${repo}/hosts/csb1/docker-image-gc.py"
conf="${repo}/hosts/csb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_docker_image_gc.py' -v
nix-instantiate --parse "${mod}" >/dev/null

grep -Fq './docker-image-gc.nix' "${conf}"
grep -Fq 'composeStack.renderedSpec.services' "${mod}"
grep -Fq 'DECLARED_REFS = builtins.toJSON declaredRefs' "${mod}"
grep -Fq 'SupplementaryGroups = [ "docker" ]' "${mod}"
grep -Fq 'RestrictAddressFamilies = [ "AF_UNIX" ]' "${mod}"
grep -Fq 'OnCalendar = "*-*-* 04:30:00"' "${mod}"
grep -Fq '@DECLARED_REFS@' "${script}"
grep -Fq '"ghcr.io/inspr-at/janus/janus-engine"' "${script}"
grep -Fq '"ghcr.io/inspr-at/janus/janus-envelope"' "${script}"
# 🔴 csb1 never-prune rule: no blanket prune, no volume calls, no inspect.
# Inspect endpoints are /containers/<id>/json and /images/<id>/json; the list endpoints have no segment.
forbidden='image prune|system prune|/(images|system|containers|volumes)/prune|volume|inspect|/(containers|images)/[^"?/]+/json|"/json'
if grep -nE "${forbidden}" "${script}" | grep -vE '^\s*[0-9]+:\s*(#|"""|.*(off limits|never touched|no inspect|takes the unmounted))'; then
  echo "T115: forbidden call in ${script}" >&2
  exit 1
fi
echo "T115 ok"
