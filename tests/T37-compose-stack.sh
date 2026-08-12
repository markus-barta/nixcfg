#!/usr/bin/env bash
# OPS-116/117 composeStack contract.
#
# The equivalence gate is the safety property the whole epic rests on: it proves
# each host's Nix spec parses to exactly the same structure as the compose YAML
# it replaces, so a migration is a reviewable no-op rather than a rewrite.
#
# Everything asserted below has already failed at least once in a controlled
# test, so none of it is theoretical:
#   * a dropped service           -> caught by the gate's service-set check
#   * a silently changed bind path -> caught by deep equality
#   * dns on a bridge service      -> caught by the gate (breaks 127.0.0.11)
#   * dns on a host-network service -> invisible to the gate, caught by the
#                                      module assertion, which is why both exist
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="${repo}/modules/shared/compose-stack/default.nix"
gate="${repo}/tests/compose_stack_gate.py"

nix-instantiate --parse "${module}" >/dev/null

# --- module contract -------------------------------------------------------
# Each of these encodes a decision that is easy to undo by accident and does not
# fail loudly at build time.

# DNS must be derived, never literal — that is the whole of OPS-114.
grep -Fq 'config.networking.nameservers' "${module}"
grep -Fq 'config.networking.search' "${module}"

# Injection is scoped to host-network services. Bridge services must keep
# Docker's embedded resolver at 127.0.0.11 or container-name resolution breaks.
grep -Fq 'isHostNetwork' "${module}"

# The reconcile is what makes switch converge containers. Without the trigger
# the module is just a fancy way of writing a file.
grep -Fq 'restartTriggers' "${module}"

# Guards that protect live data and catch the duplication coming back.
grep -Fq 'orphans named volumes' "${module}"
grep -Fq 'duplication returning' "${module}"

# --- per-host wiring -------------------------------------------------------
# The compose project name is NOT the hostname on the home hosts: those compose
# files carry no `name:` key, so compose derived the project from the containing
# directory. hsb1's docker_opus-stream-app volume rides on it. Verified against
# the live hosts 2026-08-01.
for host in hsb0 hsb1 hsb8 hsb9; do
  spec="${repo}/hosts/${host}/configuration.nix"
  grep -Fq 'modules/shared/compose-stack' "${spec}"
  grep -Fq 'project = "docker"' "${spec}" ||
    {
      echo "FAIL: ${host} compose project must stay \"docker\" — see OPS-116"
      exit 1
    }
done
for host in csb0 csb1; do
  spec="${repo}/hosts/${host}/configuration.nix"
  grep -Fq 'modules/shared/compose-stack' "${spec}"
  grep -Fq "project = \"${host}\"" "${spec}" ||
    {
      echo "FAIL: ${host} compose project must stay \"${host}\""
      exit 1
    }
done

# Relative paths only resolve if projectDirectory is set; hsb1 and hsb8 have
# none and deliberately omit it.
for host in hsb0 hsb9 csb0 csb1; do
  grep -Fq 'projectDirectory' "${repo}/hosts/${host}/configuration.nix" ||
    {
      echo "FAIL: ${host} has relative paths and needs projectDirectory"
      exit 1
    }
done

# --- NIX-352: locally built images are excluded from the weekly pull --------
# hausv-org is built ON csb1 by hausv-org/scripts/deploy.sh and never exists
# in GHCR. A stack-wide `pull` dies on the registry denial BEFORE `up -d`, so
# one unpullable image starves every other service of its weekly update
# (observed live 2026-08-08). The updater must pull an explicit service list
# that honors autoUpdate.excludeFromPull.
grep -Fq 'excludeFromPull' "${module}"
grep -Fq 'autoUpdate.excludeFromPull = [ "hausv-org" ]' "${repo}/hosts/csb1/configuration.nix"

# The rendered updater itself must prove it: hausv-org absent from the pull,
# a known-pullable service still listed, and the whole-stack `up -d` retained.
# Skipped on a dirty tree: the NIX-348 deployment-evidence guard requires
# self.rev, so csb1 only evaluates from a committed state (same skip-not-fail
# stance as the yq gate below).
if [ -z "$(git -C "${repo}" status --porcelain 2>/dev/null)" ]; then
  update_script="$(nix eval --raw "${repo}#nixosConfigurations.csb1.config.systemd.services.\"compose-csb1-update\".script")"
  if grep -q 'pull.*hausv-org' <<<"${update_script}"; then
    echo "FAIL: csb1 weekly updater still pulls hausv-org (NIX-352)"
    exit 1
  fi
  grep -q 'pull --quiet .*traefik' <<<"${update_script}" ||
    {
      echo "FAIL: csb1 weekly updater lost its explicit pull list (NIX-352)"
      exit 1
    }
  grep -q 'up -d' <<<"${update_script}" ||
    {
      echo "FAIL: csb1 weekly updater lost its up -d (NIX-352)"
      exit 1
    }
else
  echo "SKIP: dirty tree — NIX-348 evidence guard blocks csb1 eval; commit first"
fi

# --- NIX-351/NIX-353: no world-readable agenix env files on csb1 ------------
# Every compose env_file is read client-side by the root-run units; the two
# non-0400 exceptions (csb1-hausv-org-env 0440 root:users for the mba-run
# deploy path, csb1-watchtower-env 0440 root:pharos-container for pharosd's
# in-container read) are justified in configuration.nix. 0644 means every
# local account can read the secret — that class was closed by NIX-353.
if grep -n 'mode = "0644"' "${repo}/hosts/csb1/configuration.nix"; then
  echo "FAIL: csb1 declares a world-readable agenix secret (NIX-353)"
  exit 1
fi

# --- equivalence gate ------------------------------------------------------
# Needs yq for the YAML side. Skipped rather than failed when unavailable, so a
# machine without it does not turn a real regression into an unrelated error.
if command -v yq >/dev/null 2>&1; then
  python3 "${gate}" --all
else
  echo "SKIP: yq not on PATH — run: nix shell nixpkgs#yq-go -c ${0}"
fi

echo "T37 compose-stack contract OK"
