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
# SIGTERM lets the call in flight finish: a GET ends at its 30 s watchdog.
grep -Fq 'TimeoutStopSec = "180";' "${mod}"
# No boot/switch catch-up run in the middle of a deploy.
if grep -Eq 'Persistent = true' "${mod}"; then
  echo "T115: the GC timer must not be Persistent" >&2
  exit 1
fi
grep -Fq '@DECLARED_REFS@' "${script}"
# keep.d (contract v2): declared by tmpfiles, read fail-closed; the release baseline is its role files.
grep -Fq '"d /var/lib/docker-image-gc/keep.d 0755 root root -"' "${mod}"
grep -Fq 'KEEP_DIR = "/var/lib/docker-image-gc/keep.d"' "${script}"
grep -Fq 'LIVE_REFS = "aeon-live.refs"' "${script}"
grep -Fq 'PREVIOUS_REFS = "aeon-previous.refs"' "${script}"
grep -Fq 'AEON_REPO = "ghcr.io/inspr-at/aeon"' "${script}"
# Activation records are gone: the release kit states the previous release.
if grep -nE 'activations|activationScripts|RECORDS_DIR|history.json' "${script}" "${mod}"; then
  echo "T115: activation records are gone; keep.d role files replace them" >&2
  exit 1
fi
# GETs end at a real timer, not only at socket timeouts.
grep -Fq 'signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))' "${script}"
# Deploy locks: every compose deploy path, never a lock someone takes non-blocking
# (Janus Pharos: flock -n; switch-to-configuration: LockExclusiveNonblock).
for lock in /run/lock/compose-csb1.lock /run/lock/compose-hausv.lock /run/lock/compose-hausv-next.lock; do
  grep -Fq "\"${lock}\"" "${script}"
done
for lock in janus-pharos-production.lock switch-to-configuration.lock; do
  if grep -n "${lock}" "${script}" | grep -vE '^\s*[0-9]+:\s*#'; then
    echo "T115: the GC must not take ${lock}" >&2
    exit 1
  fi
done
grep -Fq 'fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' "${script}"
# Real deletes only under systemd.
grep -Fq 'if not os.environ.get("INVOCATION_ID"):' "${script}"
# Deletes by ID only: never forced, never untagged by name, parents never pruned, no client timeout.
grep -Fq "api(\"DELETE\", f\"/images/{image['Id']}?noprune=1\", timeout=None," "${script}"
if [ "$(grep -c '"DELETE"' "${script}")" -ne 1 ]; then
  echo "T115: exactly one DELETE call, by image ID" >&2
  exit 1
fi
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
