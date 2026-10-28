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
grep -Fq 'CapabilityBoundingSet = "";' "${mod}"
grep -Fq 'StateDirectory = "docker-image-gc";' "${mod}"
grep -Fq 'ReadWritePaths = [ "/run/lock" ];' "${mod}"
grep -Fq 'RestrictAddressFamilies = [ "AF_UNIX" ]' "${mod}"
grep -Fq 'OnCalendar = "*-*-* 04:30:00"' "${mod}"
# No boot/switch catch-up run in the middle of a deploy.
if grep -Eq 'Persistent = true' "${mod}"; then
  echo "T115: the GC timer must not be Persistent" >&2
  exit 1
fi
grep -Fq '@DECLARED_REFS@' "${script}"
# Deploy locks: every compose deploy path, never the Janus Pharos lock (taken with flock -n).
for lock in /run/lock/compose-csb1.lock /run/lock/compose-hausv.lock /run/lock/compose-hausv-next.lock; do
  grep -Fq "\"${lock}\"" "${script}"
done
if grep -Fq 'janus-pharos-production.lock' "${script}"; then
  echo "T115: the GC must not take the Janus Pharos lock" >&2
  exit 1
fi
# Deletes never force and never prune parents.
grep -Fq '"?noprune=1"' "${script}"
if grep -nE 'noprune=0|force=(1|true)' "${script}"; then
  echo "T115: forced or parent-pruning delete in ${script}" >&2
  exit 1
fi
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
