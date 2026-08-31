#!/usr/bin/env bash
# OPS-186: Pharos deployment evidence must reach the beacon through a DIRECTORY.
#
# /etc/pharos-deployment/evidence.json is a symlink into the active generation.
# A compose bind mount of that file pins the inode from container start, so every
# later `nixos-rebuild switch` is invisible to Pharos (2026-08-21: csb0 reported
# "6 commits behind" while current). The flake copies the document into
# /run/pharos-deployment at activation; beacons mount that directory.
#
# NIX-399 applies the same lifetime boundary to host preferences: activation
# atomically refreshes /run/pharos-preferences and beacons mount that stable
# directory, never the generation-backed /etc file.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -Fq 'system.activationScripts.pharosDeploymentEvidence' "${repo}/flake.nix"
grep -Fq 'mv -f /run/pharos-deployment/.evidence.json.tmp /run/pharos-deployment/evidence.json' "${repo}/flake.nix"
grep -Fq 'system.activationScripts.pharosHostPreferences' "${repo}/modules/common.nix"
grep -Fq \
  'install -m 0644 /etc/pharos/host-preferences.json /run/pharos-preferences/.host-preferences.json.tmp' \
  "${repo}/modules/common.nix"
grep -Fq \
  'mv -f /run/pharos-preferences/.host-preferences.json.tmp /run/pharos-preferences/host-preferences.json' \
  "${repo}/modules/common.nix"
bad=0
for spec in "${repo}"/hosts/*/docker/compose-spec.nix; do
  if grep -Fq 'pharos-deployment/evidence.json:/host' "${spec}"; then
    echo "T45: ${spec#"${repo}"/} bind-mounts the evidence FILE (stale after switch)" >&2
    bad=1
  fi
  if grep -Fq 'PHAROS_NIX_DEPLOYMENT_EVIDENCE_FILE=/host/pharos-deployment/evidence.json' "${spec}"; then
    grep -Fq '"/run/pharos-deployment:/host/pharos-deployment:ro"' "${spec}" || {
      echo "T45: ${spec#"${repo}"/} declares the evidence env but not the directory mount" >&2
      bad=1
    }
  fi
  if grep -Fq '/etc/pharos/host-preferences.json:/etc/pharos/host-preferences.json' "${spec}"; then
    echo "T45: ${spec#"${repo}"/} bind-mounts the preferences FILE (stale after switch)" >&2
    bad=1
  fi
  if grep -Fq 'PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json' "${spec}"; then
    grep -Fq '"/run/pharos-preferences:/etc/pharos:ro"' "${spec}" || {
      echo "T45: ${spec#"${repo}"/} declares preferences but not the stable directory mount" >&2
      bad=1
    }
  fi
done
[ "${bad}" -eq 0 ]
echo "T45 ok"
