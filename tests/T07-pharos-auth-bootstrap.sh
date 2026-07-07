#!/usr/bin/env bash
# T07-pharos-auth-bootstrap.sh
# Description: Validate Pharos registration-token bootstrap wiring stays value-free.
# Related PPM issues: PHAROS-37, PHAROS-40

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_NIX="$REPO_ROOT/secrets/secrets.nix"
CSB1_CONFIG="$REPO_ROOT/hosts/csb1/configuration.nix"
CSB1_COMPOSE="$REPO_ROOT/hosts/csb1/docker/docker-compose.yml"

need_line() {
  local expected="$1"
  local file="$2"
  if ! grep -Fxq "$expected" "$file"; then
    echo "missing expected line in ${file#"$REPO_ROOT"/}: $expected" >&2
    exit 1
  fi
}

need_line '  "csb1-pharos-registration-env.age".publicKeys = markus ++ csb1;' "$SECRETS_NIX"
need_line '  "pharos-beacon-hsb0-env.age".publicKeys = markus ++ hsb0;' "$SECRETS_NIX"
need_line '  "pharos-beacon-hsb1-env.age".publicKeys = markus ++ hsb1;' "$SECRETS_NIX"
need_line '  "pharos-beacon-hsb8-env.age".publicKeys = markus ++ hsb8;' "$SECRETS_NIX"
need_line '  "pharos-beacon-csb0-env.age".publicKeys = markus ++ csb0;' "$SECRETS_NIX"
need_line '  "pharos-beacon-csb1-env.age".publicKeys = markus ++ csb1;' "$SECRETS_NIX"
need_line '  age.secrets.csb1-pharos-registration-env = {' "$CSB1_CONFIG"
need_line '    path = "/run/agenix/csb1-pharos-registration-env";' "$CSB1_CONFIG"
need_line '  age.secrets.pharos-beacon-csb1-env = {' "$CSB1_CONFIG"
need_line '    path = "/run/agenix/pharos-beacon-csb1-env";' "$CSB1_CONFIG"
need_line '      - /run/agenix/csb1-pharos-registration-env' "$CSB1_COMPOSE"
need_line '      - /run/agenix/pharos-beacon-csb1-env' "$CSB1_COMPOSE"
need_line '      - PHAROS_REQUIRE_BEACON_TOKEN=0' "$CSB1_COMPOSE"

if grep -Eq 'PHAROS_REGISTRATION_TOKEN=|Bearer |BEGIN |PRIVATE KEY|pharos_[0-9A-Fa-f]{16,}' \
  "$SECRETS_NIX" "$CSB1_CONFIG" "$CSB1_COMPOSE"; then
  echo "Pharos auth bootstrap wiring contains a forbidden secret-shaped literal" >&2
  exit 1
fi

echo "ok: Pharos auth bootstrap wiring is value-free and legacy reports stay allowed"
