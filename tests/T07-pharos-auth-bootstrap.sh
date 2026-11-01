#!/usr/bin/env bash
# T07-pharos-auth-bootstrap.sh
# Description: Validate local-mode Pharos keeps registration closed without credentials.
# Related PPM issues: PHAROS-37, PHAROS-40, PHAROS-164, PHAROS-170

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_NIX="$REPO_ROOT/secrets/secrets.nix"
CSB1_CONFIG="$REPO_ROOT/hosts/csb1/configuration.nix"
CSB1_COMPOSE="$REPO_ROOT/hosts/csb1/docker/compose-spec.nix"

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
need_line '  age.secrets.pharos-beacon-csb1-env = {' "$CSB1_CONFIG"
need_line '    path = "/run/agenix/pharos-beacon-csb1-env";' "$CSB1_CONFIG"
need_line '        "/run/agenix/pharos-beacon-csb1-env"' "$CSB1_COMPOSE"
need_line '        "PHAROS_REQUIRE_BEACON_TOKEN=1"' "$CSB1_COMPOSE"
need_line '        "PHAROS_BEACON_TOKEN_MODE=local"' "$CSB1_COMPOSE"
need_line '        "PHAROS_ALLOW_LOCAL_REGISTER=false"' "$CSB1_COMPOSE"
# PHAROS-345: Pharos 2 has no policy file, so this list is the only way in. It
# keeps today's access set: the bootstrap reference plus the UX test account.
operators="$(sed -n 's/^[[:space:]]*"PHAROS_ALLOWED_OPERATORS=\([^"]*\)"$/\1/p' "$CSB1_COMPOSE")"
allowed_operators_ok() {
  if [[ "$1" =~ ^verified-email-ref:[0-9a-f]{64},operator-ref:[0-9a-f]{64}$ ]]; then
    return 0
  fi
  return 1
}
if ! allowed_operators_ok "$operators"; then
  echo "Pharos operator allowlist must hold one verified-email reference and one operator reference" >&2
  exit 1
fi
aaa='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
while IFS= read -r bad; do
  if allowed_operators_ok "$bad"; then
    echo "allowlist predicate accepted a malformed list: $bad" >&2
    exit 1
  fi
done <<EOF
verified-email-ref:$aaa
operator-ref:$aaa
person@example.com,operator-ref:$aaa
verified-email-ref:$aaa,person@example.com
verified-email-ref:$aaa,operator-ref:abc
verified-email-ref:$aaa,operator-ref:${aaa}z
EOF
# A second assignment would override the checked value, so it can't count as valid.
if allowed_operators_ok "verified-email-ref:$aaa,operator-ref:$aaa"$'\n'"person@example.com"; then
  echo "allowlist predicate accepted a second line" >&2
  exit 1
fi
forbid_text 'PHAROS_ACCESS_POLICY_FILE' "$CSB1_COMPOSE"
forbid_text 'access-policy.json' "$CSB1_COMPOSE"
forbid_text 'csb1-pharos-registration-env' "$CSB1_CONFIG"
forbid_text 'csb1-pharos-registration-env' "$CSB1_COMPOSE"

if grep -Eq 'PHAROS_REGISTRATION_TOKEN=|Bearer |BEGIN |PRIVATE KEY|pharos_[0-9A-Fa-f]{16,}' \
  "$SECRETS_NIX" "$CSB1_CONFIG" "$CSB1_COMPOSE"; then
  echo "Pharos auth bootstrap wiring contains a forbidden secret-shaped literal" >&2
  exit 1
fi

echo "ok: local-mode Pharos has strict machine auth and explicit OIDC authorization identifiers"
