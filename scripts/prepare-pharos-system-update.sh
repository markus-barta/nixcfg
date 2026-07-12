#!/usr/bin/env bash
set -euo pipefail

umask 077

source_host=${1-}
request_id=${2-}
output_file=${GITHUB_OUTPUT:-${PHAROS_UPDATE_OUTPUT:-}}

fail() {
  printf 'pharos_system_update=failed reason=%s\n' "$1" >&2
  exit 1
}

[[ "$source_host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail "invalid_source_host"
[[ "$request_id" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || fail "invalid_request_id"
[[ -f flake.nix && -f flake.lock && -d .git ]] || fail "not_nixcfg_checkout"

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  fail "checkout_not_clean"
fi

work_dir=$(mktemp -d)
cleanup() {
  chmod -R u+w "$work_dir" 2>/dev/null || true
  rm -r "$work_dir"
}
trap cleanup EXIT

cp flake.lock "$work_dir/flake-lock-before.json"

if ! nix eval --no-update-lock-file --json \
  .#nixosConfigurations \
  --apply 'configs: builtins.attrNames configs' \
  >"$work_dir/hosts.json" 2>"$work_dir/host-discovery.log"; then
  fail "host_discovery_failed"
fi

if ! jq -e '
  type == "array"
  and length > 0
  and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
' "$work_dir/hosts.json" >/dev/null; then
  fail "invalid_host_inventory"
fi

jq -r '.[]' "$work_dir/hosts.json" | LC_ALL=C sort -u >"$work_dir/hosts"
if ! grep -Fxq "$source_host" "$work_dir/hosts"; then
  fail "source_host_not_active"
fi

if ! nix flake update >"$work_dir/update.log" 2>&1; then
  fail "flake_update_failed"
fi

tracked_paths=$(git diff --name-only)
staged_paths=$(git diff --cached --name-only)
untracked_paths=$(git ls-files --others --exclude-standard)

[[ -z "$staged_paths" && -z "$untracked_paths" ]] || fail "unexpected_update_output"
if [[ -n "$tracked_paths" && "$tracked_paths" != "flake.lock" ]]; then
  fail "unexpected_update_output"
fi

changed=false
changed_inputs=none
if ! cmp -s "$work_dir/flake-lock-before.json" flake.lock; then
  changed=true
  if ! jq -e . flake.lock >/dev/null; then
    fail "invalid_updated_lock"
  fi

  jq -r --slurpfile before "$work_dir/flake-lock-before.json" '
    (($before[0].nodes | keys) + (.nodes | keys) | unique)[] as $name
    | select(
        (($before[0].nodes[$name].locked // $before[0].nodes[$name].original // null)
          !=
         (.nodes[$name].locked // .nodes[$name].original // null))
      )
    | $name
  ' flake.lock | LC_ALL=C sort -u >"$work_dir/changed-inputs"

  if [[ ! -s "$work_dir/changed-inputs" ]]; then
    fail "changed_input_detection_failed"
  fi
  if grep -Evq '^[A-Za-z0-9._+-]+$' "$work_dir/changed-inputs"; then
    fail "invalid_changed_input_name"
  fi
  changed_inputs=$(paste -sd, "$work_dir/changed-inputs" | sed 's/,/, /g')
fi

validated_count=0
while IFS= read -r host; do
  [[ -n "$host" ]] || continue
  if ! nix eval --no-update-lock-file \
    ".#nixosConfigurations.${host}.config.system.build.toplevel.drvPath" \
    >"$work_dir/eval-${host}.out" 2>"$work_dir/eval-${host}.log"; then
    fail "host_evaluation_failed:${host}"
  fi
  validated_count=$((validated_count + 1))
done <"$work_dir/hosts"

[[ "$validated_count" -gt 0 ]] || fail "no_hosts_validated"

tracked_paths=$(git diff --name-only)
staged_paths=$(git diff --cached --name-only)
untracked_paths=$(git ls-files --others --exclude-standard)
[[ -z "$staged_paths" && -z "$untracked_paths" ]] || fail "validation_changed_checkout"
if [[ "$changed" == true ]]; then
  [[ "$tracked_paths" == "flake.lock" ]] || fail "validation_changed_checkout"
else
  [[ -z "$tracked_paths" ]] || fail "validation_changed_checkout"
fi

validated_hosts=$(paste -sd, "$work_dir/hosts" | sed 's/,/, /g')
if [[ -n "$output_file" ]]; then
  {
    printf 'changed=%s\n' "$changed"
    printf 'changed_inputs=%s\n' "$changed_inputs"
    printf 'validated_hosts=%s\n' "$validated_hosts"
    printf 'validated_host_count=%s\n' "$validated_count"
  } >>"$output_file"
fi

printf 'pharos_system_update=prepared changed=%s\n' "$changed"
printf 'changed_inputs=%s\n' "$changed_inputs"
printf 'validated_hosts=%s\n' "$validated_hosts"
printf 'deployment=not_performed\n'
