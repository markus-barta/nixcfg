#!/usr/bin/env bash
# T48 — NIX-584: classic Paimos delivery/container must stay retired.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
redirect="$repo_root/hosts/csb1/ppm-aeon-redirect-routing.nix"

fail() {
  printf 'T48 failed: %s\n' "$*" >&2
  exit 1
}

[[ ! -e "$repo_root/hosts/csb1/paimos-delivery-stage.nix" ]] ||
  fail 'classic paimos-delivery-stage.nix must not return'
[[ ! -e "$repo_root/hosts/csb1/ppm-cutover.nix" ]] ||
  fail 'ppm-cutover.nix must not return'
[[ ! -e "$repo_root/hosts/csb1/ppm-cutover-routing.nix" ]] ||
  fail 'ppm-cutover-routing.nix must not return'

nix-instantiate --parse "$compose" >/dev/null
nix-instantiate --parse "$host_config" >/dev/null
nix-instantiate --parse "$redirect" >/dev/null

grep -Fq 'import ./ppm-aeon-redirect-routing.nix' "$host_config" ||
  fail 'csb1 must import the unconditional Aeon redirect fragment'
grep -Fq 'aeon.barta.cm/from-classic' "$redirect" ||
  fail 'redirect fragment must send browsers to Aeon /from-classic'
grep -Fq '/from-classic/api' "$redirect" ||
  fail 'redirect fragment must rewrite classic API paths to Aeon /from-classic/api'
if grep -Eq 'pml\.barta\.cm' "$redirect" "$host_config" "$compose"; then
  fail 'pml.barta.cm must not remain in csb1 routing or compose'
fi
if grep -Fq 'paimos-delivery-stage.nix' "$host_config" "$compose"; then
  fail 'classic delivery stage must stay unwired'
fi
if grep -Fq 'inspr.pharosPaimosDelivery' "$host_config"; then
  fail 'pharos Paimos v1 delivery adapter must stay unwired on csb1'
fi
if grep -Fq 'inspr.janusPaimosDependencyReporter' "$host_config"; then
  fail 'janus classic Paimos reporter must stay unwired on csb1'
fi

has_ppm=$(nix eval --impure --json --expr "(import $compose).services ? ppm")
[[ "$has_ppm" == "false" ]] || fail "classic ppm service must not be in compose, got $has_ppm"
has_volume=$(nix eval --impure --json --expr "(import $compose).volumes ? ppm_data")
[[ "$has_volume" == "true" ]] || fail "ppm_data volume must remain declared so compose does not delete it"

printf 'T48 passed: classic Paimos delivery and container are retired; Aeon redirects stay; ppm_data volume remains\n'
