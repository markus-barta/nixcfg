#!/usr/bin/env bash
set -euo pipefail

higgsfield_bin="${HIGGSFIELD_BIN:-@higgsfield@}"
expected_version="@version@"

case "$higgsfield_bin" in
/nix/store/*/bin/higgsfield) ;;
*)
  printf 'higgsfield-smoke: binary is not an immutable Nix store path\n' >&2
  exit 1
  ;;
esac

version_output="$("$higgsfield_bin" --version)"
case "$version_output" in
"higgsfield $expected_version "*) ;;
*)
  printf 'higgsfield-smoke: unexpected version\n' >&2
  exit 1
  ;;
esac

# Capture authenticated responses in memory and validate only their schema.
# Never print the account document: it includes the operator's email and credit
# balance. Authentication remains in Higgsfield's external user state.
if ! account_json="$("$higgsfield_bin" account status --json 2>/dev/null)"; then
  printf 'higgsfield-smoke: authenticated account read failed\n' >&2
  exit 1
fi
printf '%s' "$account_json" | @jq@ -e '
  type == "object"
  and (.email | type == "string" and length > 0)
  and (.subscription_plan_type | type == "string" and length > 0)
  and (.credits | type == "number")
' >/dev/null || {
  printf 'higgsfield-smoke: account schema invalid\n' >&2
  exit 1
}
unset account_json

# Ask for the complete current image catalog rather than a curated model list.
# Validate every record, then expose only a count and a digest of the canonical
# public catalog fields. Raw provider payloads are deliberately not logged.
if ! models_json="$("$higgsfield_bin" model list --image --json 2>/dev/null)"; then
  printf 'higgsfield-smoke: image model catalog read failed\n' >&2
  exit 1
fi
printf '%s' "$models_json" | @jq@ -e '
  type == "array"
  and length > 0
  and all(.[].type; . == "image")
  and all(.[]; (.display_name | type == "string" and length > 0))
  and all(.[]; (.job_type | type == "string" and length > 0))
' >/dev/null || {
  printf 'higgsfield-smoke: image model catalog schema invalid\n' >&2
  exit 1
}
model_count=$(printf '%s' "$models_json" | @jq@ -r 'length')
catalog_digest=$(
  printf '%s' "$models_json" |
    @jq@ -cS 'map({display_name, job_type, type}) | sort_by(.job_type, .display_name)' |
    @sha256sum@ |
    while IFS=' ' read -r digest _rest; do printf '%s' "$digest"; done
)
unset models_json

printf 'higgsfield-smoke: version=%s account=authenticated image_models=%s catalog_sha256=%s\n' \
  "$expected_version" "$model_count" "$catalog_digest"
