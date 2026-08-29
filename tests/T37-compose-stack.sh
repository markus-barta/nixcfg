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

# NIX-384: private registries. The login must be scoped to a per-unit runtime
# docker config (never root's ~/.docker), fed by --password-stdin, and removed
# again after the unit's work.
grep -Fq 'registryLogins' "${module}"
# shellcheck disable=SC2016 # literal Nix interpolation, matched verbatim in the module source
grep -Fq 'environment.DOCKER_CONFIG = "/run/${dir}"' "${module}"
grep -Fq -- '--password-stdin' "${module}"
# shellcheck disable=SC2016 # literal Nix interpolation, matched verbatim in the module source
grep -Fq 'rm -f /run/${dir}/config.json' "${module}"
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

# --- NIX-352: locally built images can be excluded from weekly pull ----------
# The module retains the explicit exclusion mechanism for other local images.
# HAUSV now belongs to its private instance project and must not remain in the
# host's monolithic compose specification or updater.
grep -Fq 'excludeFromPull' "${module}"
if grep -Fq 'hausv-org = {' "${repo}/hosts/csb1/docker/compose-spec.nix"; then
  echo "FAIL: HAUSV must be owned by the private hausv-jhw22 compose project"
  exit 1
fi

# The rendered updater itself must prove it: hausv-org absent, pull retained,
# and the whole-stack `up -d` retained.
# Skipped on a dirty tree: the NIX-348 deployment-evidence guard requires
# self.rev, so csb1 only evaluates from a committed state (same skip-not-fail
# stance as the yq gate below).
if [ -z "$(git -C "${repo}" status --porcelain 2>/dev/null)" ]; then
  update_script="$(nix eval --raw "${repo}#nixosConfigurations.csb1.config.systemd.services.\"compose-csb1-update\".script")"
  if grep -q 'pull.*hausv-org' <<<"${update_script}"; then
    echo "FAIL: csb1 weekly updater still pulls hausv-org (NIX-352)"
    exit 1
  fi
  grep -q 'pull --quiet' <<<"${update_script}" ||
    {
      echo "FAIL: csb1 weekly updater lost its pull step (NIX-352)"
      exit 1
    }
  grep -q 'up -d' <<<"${update_script}" ||
    {
      echo "FAIL: csb1 weekly updater lost its up -d (NIX-352)"
      exit 1
    }
  # NIX-384: once the pull token exists, both root-run units must log in to
  # ghcr.io before compose touches the private inspr-auth image.
  if [ -f "${repo}/secrets/csb1-inspr-site-ghcr-pull.age" ]; then
    for unit in compose-csb1 compose-csb1-update; do
      pre_start="$(nix eval --raw "${repo}#nixosConfigurations.csb1.config.systemd.services.\"${unit}\".preStart")"
      grep -q 'docker login ghcr.io' <<<"${pre_start}" ||
        {
          echo "FAIL: ${unit} does not log in to ghcr.io before compose (NIX-384)"
          exit 1
        }
    done
  fi
else
  echo "SKIP: dirty tree — NIX-348 evidence guard blocks csb1 eval; commit first"
fi

# NIX-385: hsb8 intentionally has no host notification transport. Keep the
# operational decision visible both on its dashboard and in the runbook until a
# reviewed fleet-wide transport exists; do not silently regress to an implied
# alert path that operators cannot rely on.
grep -Fq 'foot = "Sat 05:05 · intentionally silent; check journal";' \
  "${repo}/hosts/hsb8/configuration.nix" ||
  {
    echo "FAIL: hsb8 HostDash no longer states the compose-update notification decision (NIX-385)"
    exit 1
  }
grep -Fq '**Decision (NIX-385): keep this updater intentionally silent for now.**' \
  "${repo}/hosts/hsb8/docs/RUNBOOK.md" ||
  {
    echo "FAIL: hsb8 runbook no longer records the compose-update notification decision (NIX-385)"
    exit 1
  }

# --- NIX-351/NIX-353/NIX-356: no world-readable agenix secrets, fleet-wide --
# Every compose env_file is read client-side by the root-run units; the
# non-0400 exceptions (csb1-hausv-org-env 0440 root:users for the mba-run
# deploy path, csb1-watchtower-env 0440 owner-10001 for pharosd's
# in-container read) are justified in configuration.nix. World-readable means
# every local account can read the secret — csb1 was closed by NIX-353,
# csb0+hsb1 by NIX-356. Both spellings count: NIX-356 found four mosquitto
# files written as "644" that an exact "0644" grep missed. Today every match
# under hosts/ is an age.secrets block; if a legitimate non-secret 644 mode
# ever lands here, replace this with an evaluated octal check + allowlist
# instead of weakening the grep.
if grep -rnE 'mode = "0?644"' "${repo}/hosts/" --include='*.nix'; then
  echo "FAIL: world-readable agenix secret mode under hosts/ (NIX-353/NIX-356)"
  exit 1
fi

# --- NIX-383: paimos.com is redirect-only -------------------------------
# Both the production spec and the OPS-136 drill must keep the Caddyfile that
# implements the redirect, while never reviving the unused legacy site mount.
for spec in \
  "${repo}/hosts/csb1/docker/compose-spec.nix" \
  "${repo}/hosts/csb1/docker/ops136/drill-override.yml"; do
  grep -Fq '/home/mba/docker/paimos/Caddyfile:/etc/caddy/Caddyfile:ro' "${spec}" ||
    {
      echo "FAIL: ${spec#"${repo}/"} lost the paimos.com redirect Caddyfile (NIX-383)"
      exit 1
    }
  if grep -Fq '/home/mba/docker/paimos/site' "${spec}"; then
    echo "FAIL: ${spec#"${repo}/"} revived the unused paimos.com site bind (NIX-383)"
    exit 1
  fi
done

# --- equivalence gate ------------------------------------------------------
# Needs yq for the YAML side. OPS-188: this used to print SKIP and exit 0, so on
# any machine without yq the equivalence gate -- the entire safety property of
# this test -- silently did not run while the test still reported success.
# A missing dependency is now exit 2 (unrunnable), never a pass.
if ! command -v yq >/dev/null 2>&1; then
  echo "T37: yq is required for the equivalence gate — run: nix shell nixpkgs#yq-go -c ${0}" >&2
  exit 2
fi
python3 "${gate}" --all

echo "T37 compose-stack contract OK"
