#!/usr/bin/env bash
# T04-markus-ssh-routes.sh
# Verifies the additive markus SSH route matrix without changing live SSH config.
# Related PPM issue: NIX-271

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_CONFIG="${HOME_CONFIG:-markus@mbp2607}"

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

PASSED=0
FAILED=0

pass() {
  printf 'PASS %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILED=$((FAILED + 1))
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

setting_value() {
  local alias="$1"
  local key="$2"
  local attr=".#homeConfigurations.\"${HOME_CONFIG}\".config.programs.ssh.settings.\"${alias}\".data.\"${key}\""

  nix eval "${NIX_FLAGS[@]}" "$attr" --json | jq -r 'tostring'
}

expect_setting() {
  local alias="$1"
  local key="$2"
  local expected="$3"
  local actual

  if ! actual="$(setting_value "$alias" "$key")"; then
    fail "${alias}.${key}: eval failed"
    return
  fi

  if [[ "$actual" == "$expected" ]]; then
    pass "${alias}.${key} == ${expected}"
  else
    fail "${alias}.${key}: expected ${expected}, got ${actual}"
  fi
}

expect_alias() {
  local alias="$1"
  local hostname="$2"
  local user="$3"

  expect_setting "$alias" hostname "$hostname"
  expect_setting "$alias" user "$user"
}

expect_cloud_alias() {
  local alias="$1"
  local hostname="$2"
  local user="$3"

  expect_alias "$alias" "$hostname" "$user"
  expect_setting "$alias" port "2222"
}

expect_lan_markus_routes() {
  local host="$1"
  local ip="$2"
  local lan_name="$3"
  local ts_name="$4"

  expect_alias "${host}-markus" "$ip" markus
  expect_alias "${host}-markus-lan" "$lan_name" markus
  expect_alias "${host}-markus-ip" "$ip" markus
  expect_alias "${host}-markus-ts" "$ts_name" markus
}

cd "$REPO_ROOT"

need_cmd nix
need_cmd jq

if ((FAILED > 0)); then
  exit 1
fi

printf 'T04 markus SSH routes (HOME_CONFIG=%s)\n\n' "$HOME_CONFIG"

# Bare aliases remain on the established mba login during the additive phase.
expect_alias hsb0 192.168.1.99 mba
expect_alias hsb1 192.168.1.101 mba
expect_alias hsb8 192.168.1.100 mba
expect_alias hsb9 192.168.1.200 mba
expect_alias gpc0 192.168.1.154 mba
expect_cloud_alias csb0 csb0.ts.barta.cm mba
expect_cloud_alias csb1 csb1.ts.barta.cm mba

# Explicit markus routes.
expect_lan_markus_routes hsb0 192.168.1.99 hsb0.lan hsb0.ts.barta.cm
expect_lan_markus_routes hsb1 192.168.1.101 hsb1.lan hsb1.ts.barta.cm
expect_lan_markus_routes hsb8 192.168.1.100 hsb8.lan hsb8.ts.barta.cm
expect_lan_markus_routes hsb9 192.168.1.200 hsb9.lan hsb9.ts.barta.cm
expect_lan_markus_routes gpc0 192.168.1.154 gpc0.lan gpc0.ts.barta.cm

expect_cloud_alias csb0-markus cs0.barta.cm markus
expect_cloud_alias csb0-markus-ip 89.58.63.96 markus
expect_cloud_alias csb0-markus-ts csb0.ts.barta.cm markus
expect_cloud_alias csb1-markus cs1.barta.cm markus
expect_cloud_alias csb1-markus-ip 152.53.64.166 markus
expect_cloud_alias csb1-markus-ts csb1.ts.barta.cm markus

printf '\nSummary: %s passed, %s failed\n' "$PASSED" "$FAILED"

if ((FAILED > 0)); then
  exit 1
fi
