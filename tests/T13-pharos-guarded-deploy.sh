#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/pharos-guarded-deploy/default.nix"
apply="$repo_root/modules/pharos-guarded-deploy/apply.sh"
rollback="$repo_root/modules/pharos-guarded-deploy/rollback.sh"
bootstrap="$repo_root/modules/pharos-guarded-deploy/bootstrap.sh"
review="$repo_root/modules/pharos-guarded-deploy/review.sh"
system_update="$repo_root/modules/pharos-guarded-deploy/system-update.sh"
action_agent="$repo_root/modules/pharos-guarded-deploy/action-agent.sh"
host_config="$repo_root/hosts/hsb8/configuration.nix"
host_compose="$repo_root/hosts/hsb8/docker/docker-compose.yml"

bash -n "$apply" "$rollback" "$bootstrap" "$review" "$system_update" "$action_agent"

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

apply_ref="sec_$(printf 'pharos-deploy\0PHAROS_APPLY_HSB8' | digest | cut -c1-20)"
rollback_ref="sec_$(printf 'pharos-deploy\0PHAROS_ROLLBACK_HSB8' | digest | cut -c1-20)"
update_ref="sec_$(printf 'pharos-deploy\0PHAROS_UPDATE_HSB8' | digest | cut -c1-20)"
[ "$apply_ref" != "$rollback_ref" ]
[ "$apply_ref" != "$update_ref" ]
[ "$rollback_ref" != "$update_ref" ]
grep -Fq "applySecretRef = \"$apply_ref\";" "$host_config"
grep -Fq "rollbackSecretRef = \"$rollback_ref\";" "$host_config"
grep -Fq "updateSecretRef = \"$update_ref\";" "$host_config"

grep -Fq 'classification = "high_value"' "$module"
grep -Fq 'allowed_args = []' "$module"
[ "$(grep -Fc 'allowed_args = []' "$module")" -eq 3 ]
# These are literal Nix and shell source assertions.
# shellcheck disable=SC2016
grep -Fq 'profile.${applySecretName}' "$module"
# shellcheck disable=SC2016
grep -Fq 'profile.${rollbackSecretName}' "$module"
grep -Fq -- '--egress hook_guarded' "$review"
grep -Fq -- '--revoke-approval' "$review"
grep -Fq -- '--permit-ttl-seconds 240' "$review"
grep -Fq 'profile.@UPDATE_SECRET_NAME@' "$review"
grep -Fq "stage='approval'" "$review"
grep -Fq 'pharos_guarded_deploy=failed action=%s stage=%s failure_gate=%s value_returned=false' "$review"
grep -Fq 'pharos-host-action-agent' "$module"
grep -Fq 'pharos-guarded-system-update' "$module"

backup_line=$(grep -n "phase='backup'" "$apply" | cut -d: -f1)
switch_line=$(grep -n "phase='switch'" "$apply" | cut -d: -f1)
[ "$backup_line" -lt "$switch_line" ]
# shellcheck disable=SC2016
grep -Fq '[ "${#changed_paths[@]}" -eq 1 ]' "$apply"
# shellcheck disable=SC2016
grep -Fq '[ "${changed_paths[0]}" = "$PREFERENCES_PATH" ]' "$apply"
# shellcheck disable=SC2016
grep -Fq 'del(.hosts[$host])' "$apply"
# shellcheck disable=SC2016
grep -Fq 'zfs snapshot -r "$snapshot"' "$apply"
grep -Fq 'snapshot_count' "$apply"
grep -Fq 'switch-to-configuration' "$apply"
grep -Fq 'switch-to-configuration' "$rollback"
# shellcheck disable=SC2016
grep -Fq 'docker cp "$BEACON_CONTAINER:/etc/pharos/host-preferences.json"' "$apply"
# shellcheck disable=SC2016
grep -Fq 'docker cp "$HOSTDASH_CONTAINER:/usr/share/nginx/html/manifest.json"' "$apply"
grep -Fq 'restart_and_verify_runtime automatic-rollback' "$apply"
grep -Fq 'restart_and_verify_runtime automatic-recovery' "$rollback"

grep -Fq 'PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json' "$host_compose"
grep -Fq '/etc/pharos/host-preferences.json:/etc/pharos/host-preferences.json:ro' "$host_compose"
grep -Fq 'environment.etc."pharos/host-preferences.json".source = ./pharos-host-preferences.json;' \
  "$repo_root/modules/common.nix"

if grep -ERq 'git reset|git clean|rm -rf|docker compose (down|restart|rm)' \
  "$repo_root/modules/pharos-guarded-deploy"; then
  echo 'unsafe broad operation found in guarded deploy module' >&2
  exit 1
fi
if grep -ERq '^[[:space:]]*eval[[:space:]]' "$repo_root/modules/pharos-guarded-deploy"; then
  echo 'shell eval found in guarded deploy module' >&2
  exit 1
fi

echo 'pharos_guarded_deploy=passed'
