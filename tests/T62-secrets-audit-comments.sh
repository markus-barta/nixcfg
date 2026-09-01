#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
audit=${SECRETS_AUDIT_UNDER_TEST:-"$repo_root/scripts/secrets-audit.sh"}
fixture_root=$(mktemp -d)
fixture_repo="$fixture_root/nixcfg"

cleanup() {
  chmod -R u+w "$fixture_root"
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

mkdir -p "$fixture_repo/secrets"
git -C "$fixture_repo" init --quiet
: >"$fixture_repo/secrets/fixture.age"

write_declarations() {
  printf '%s\n' \
    '{' \
    '  "fixture.age".publicKeys = [ ];' \
    "$1" \
    '}' >"$fixture_repo/secrets/secrets.nix"
}

write_declarations '  # documented wildcard: services/*/credential.age'
wildcard_output=$(cd "$fixture_repo" && bash "$audit" --quiet)
if [[ -n "$wildcard_output" ]]; then
  printf 'secrets_audit_comments=failed reason=line_comment_produced_output\n' >&2
  exit 1
fi

write_declarations '  /* real block comment */'
block_output=""
block_status=0
block_output=$(cd "$fixture_repo" && bash "$audit" --quiet 2>&1) || block_status=$?
if [[ $block_status -ne 2 ]]; then
  printf 'secrets_audit_comments=failed reason=block_comment_status status=%s\n' \
    "$block_status" >&2
  exit 1
fi
if [[ "$block_output" != *'secrets.nix uses block comments'* ]]; then
  printf 'secrets_audit_comments=failed reason=block_comment_verdict\n' >&2
  exit 1
fi

printf 'secrets_audit_comments=passed fixtures=2 payloads_read=0\n'
