#!/usr/bin/env bash
# T07-pharos-auth-bootstrap.sh
# Description: Validate Janus-mode Pharos has no local registration credential wiring.
# Related PPM issues: PHAROS-37, PHAROS-40, PHAROS-164, PHAROS-170

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_NIX="$REPO_ROOT/secrets/secrets.nix"
CSB1_CONFIG="$REPO_ROOT/hosts/csb1/configuration.nix"
CSB1_COMPOSE="$REPO_ROOT/hosts/csb1/docker/docker-compose.yml"
ACCESS_POLICY="$REPO_ROOT/hosts/csb1/docker/pharos/access-policy.json"

need_line() {
  local expected="$1"
  local file="$2"
  if ! grep -Fxq "$expected" "$file"; then
    echo "missing expected line in ${file#"$REPO_ROOT"/}: $expected" >&2
    exit 1
  fi
}

forbid_text() {
  local forbidden="$1"
  local file="$2"
  if grep -Fq "$forbidden" "$file"; then
    echo "forbidden obsolete registration wiring in ${file#"$REPO_ROOT"/}" >&2
    exit 1
  fi
}

need_line '  "pharos-beacon-hsb0-env.age".publicKeys = markus ++ hsb0;' "$SECRETS_NIX"
need_line '  "pharos-beacon-hsb1-env.age".publicKeys = markus ++ hsb1;' "$SECRETS_NIX"
need_line '  "pharos-beacon-hsb8-env.age".publicKeys = markus ++ hsb8;' "$SECRETS_NIX"
need_line '  "pharos-beacon-hsb9-env.age".publicKeys = markus ++ hsb9;' "$SECRETS_NIX"
need_line '  "pharos-beacon-csb0-env.age".publicKeys = markus ++ csb0;' "$SECRETS_NIX"
need_line '  "pharos-beacon-csb1-env.age".publicKeys = markus ++ csb1;' "$SECRETS_NIX"
need_line '  "pharos-beacon-gpc0-env.age".publicKeys = markus ++ gpc0;' "$SECRETS_NIX"
need_line '  age.secrets.pharos-beacon-csb1-env = {' "$CSB1_CONFIG"
need_line '    path = "/run/agenix/pharos-beacon-csb1-env";' "$CSB1_CONFIG"
need_line '      - /run/agenix/pharos-beacon-csb1-env' "$CSB1_COMPOSE"
need_line '      - PHAROS_REQUIRE_BEACON_TOKEN=1' "$CSB1_COMPOSE"
need_line '      - PHAROS_BEACON_TOKEN_MODE=janus' "$CSB1_COMPOSE"
operator_ref="$(sed -n 's/^[[:space:]]*- PHAROS_ALLOWED_OPERATORS=\(verified-email-ref:[0-9a-f]\{64\}\)$/\1/p' "$CSB1_COMPOSE")"
if [[ ! "$operator_ref" =~ ^verified-email-ref:[0-9a-f]{64}$ ]]; then
  echo "Pharos operator allowlist must use one value-free verified-email reference" >&2
  exit 1
fi
if ! jq -e --arg operator_ref "$operator_ref" \
  '.grants | length > 0 and all(.[]; .identifiers == [$operator_ref])' \
  "$ACCESS_POLICY" >/dev/null; then
  echo "Pharos access policy must use the same value-free verified-email reference" >&2
  exit 1
fi
if grep -Eq '"identifiers"[[:space:]]*:[[:space:]]*\[[^]]*"(email:|[^" ]*@)' "$ACCESS_POLICY"; then
  echo "Pharos access policy contains a mutable or unprefixed identifier" >&2
  exit 1
fi
forbid_text 'csb1-pharos-registration-env' "$CSB1_CONFIG"
forbid_text 'csb1-pharos-registration-env' "$CSB1_COMPOSE"

if grep -Eq 'PHAROS_REGISTRATION_TOKEN=|Bearer |BEGIN |PRIVATE KEY|pharos_[0-9A-Fa-f]{16,}' \
  "$SECRETS_NIX" "$CSB1_CONFIG" "$CSB1_COMPOSE"; then
  echo "Pharos auth bootstrap wiring contains a forbidden secret-shaped literal" >&2
  exit 1
fi

echo "ok: Janus-mode Pharos has strict machine auth and explicit OIDC authorization identifiers"
