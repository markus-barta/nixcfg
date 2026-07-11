#!/usr/bin/env bash
set -Eeuo pipefail

readonly HOST='@HOST@'
readonly ZFS_POOL='@ZFS_POOL@'
readonly REPO_URL='@REPO_URL@'
readonly BEACON_CONTAINER='@BEACON_CONTAINER@'
readonly HOSTDASH_CONTAINER='@HOSTDASH_CONTAINER@'
readonly STATE_DIR='/var/lib/pharos-guarded-deploy'
readonly PREFERENCES_PATH='modules/pharos-host-preferences.json'
readonly LIVE_MANIFEST="/etc/hostdash/$HOST/share/hostdash-$HOST/manifest.json"

run_id=$(date -u +%Y%m%dT%H%M%SZ)
run_dir="$STATE_DIR/runs/$run_id-apply"
detail_log="$run_dir/detail.log"
result_file="$STATE_DIR/results/latest.json"
phase='preflight'
switch_attempted=0
old_system=''
snapshot=''

mkdir -p "$run_dir" "$STATE_DIR/results"
chmod 0700 "$run_dir" "$STATE_DIR/results"
touch "$detail_log"
chmod 0600 "$detail_log"
exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || {
  printf 'host=%s action=apply status=blocked reason=deployment_in_progress value_returned=false\n' "$HOST" >&2
  exit 1
}

write_result() {
  local status=$1
  local rollback=$2
  local tmp="${result_file}.tmp"
  jq -n \
    --arg host "$HOST" \
    --arg action apply \
    --arg status "$status" \
    --arg phase "$phase" \
    --arg backup_snapshot "$snapshot" \
    --arg rollback "$rollback" \
    --arg completed_at "$(date -u +%FT%TZ)" \
    '{schema:"inspr.pharos.guarded-deploy-result.v1",host:$host,action:$action,status:$status,phase:$phase,backup_snapshot:$backup_snapshot,rollback:$rollback,completed_at:$completed_at,value_returned:false}' \
    >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$result_file"
}

runtime_matches_active() {
  local label=$1
  local beacon_preferences="$run_dir/$label-beacon-preferences.json"
  local hostdash_manifest="$run_dir/$label-hostdash-manifest.json"

  docker cp "$BEACON_CONTAINER:/etc/pharos/host-preferences.json" "$beacon_preferences" \
    >>"$detail_log" 2>&1 || return 1
  docker cp "$HOSTDASH_CONTAINER:/usr/share/nginx/html/manifest.json" "$hostdash_manifest" \
    >>"$detail_log" 2>&1 || return 1
  chmod 0600 "$beacon_preferences" "$hostdash_manifest"
  cmp -s "$beacon_preferences" /etc/pharos/host-preferences.json || return 1
  cmp -s "$hostdash_manifest" "$LIVE_MANIFEST" || return 1
}

restart_and_verify_runtime() {
  local label=$1
  local beacon_since

  beacon_since=$(date -u +%FT%TZ)
  docker restart "$HOSTDASH_CONTAINER" "$BEACON_CONTAINER" >>"$detail_log" 2>&1 || return 1
  for _ in $(seq 1 45); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$BEACON_CONTAINER")" = true ] &&
      [ "$(docker inspect --format '{{.State.Running}}' "$HOSTDASH_CONTAINER")" = true ] &&
      docker logs --since "$beacon_since" "$BEACON_CONTAINER" 2>&1 |
      grep -Eq "reported $HOST .*HTTP (200|204)"; then
      break
    fi
    sleep 2
  done
  docker logs --since "$beacon_since" "$BEACON_CONTAINER" 2>&1 |
    grep -Eq "reported $HOST .*HTTP (200|204)" || return 1
  runtime_matches_active "$label" || return 1
  curl --fail --silent --show-error --max-time 10 http://127.0.0.1/ >/dev/null || return 1
  [ "$(systemctl --failed --no-legend | wc -l | tr -d ' ')" -eq 0 ] || return 1
}

on_error() {
  local status=$?
  local rollback='not_required'
  trap - ERR
  set +e
  if [ "$switch_attempted" -eq 1 ] && [ -n "$old_system" ] && [ -x "$old_system/bin/switch-to-configuration" ]; then
    rollback='failed'
    if "$old_system/bin/switch-to-configuration" switch >>"$detail_log" 2>&1 &&
      [ "$(readlink -f /run/current-system)" = "$old_system" ] &&
      restart_and_verify_runtime automatic-rollback; then
      rollback='succeeded'
    fi
  fi
  write_result failed "$rollback"
  printf 'host=%s action=apply status=failed phase=%s rollback=%s value_returned=false\n' \
    "$HOST" "$phase" "$rollback" >&2
  exit "$status"
}
trap on_error ERR

[ "$(id -u)" -eq 0 ]
[ -n "${PHAROS_DEPLOY_CAPABILITY:-}" ]
unset PHAROS_DEPLOY_CAPABILITY

phase='kernel_gate'
running_kernel=$(uname -r)
mapfile -t configured_kernels < <(
  find -L /run/current-system/kernel-modules/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
)
[ "${#configured_kernels[@]}" -eq 1 ]
[ "${configured_kernels[0]}" = "$running_kernel" ]

phase='backup'
snapshot="$ZFS_POOL@pharos-predeploy-$run_id"
dataset_count=$(zfs list -H -r -o name "$ZFS_POOL" | wc -l | tr -d ' ')
zfs snapshot -r "$snapshot" >>"$detail_log" 2>&1
snapshot_count=$(
  zfs list -H -t snapshot -r -o name "$ZFS_POOL" |
    awk -F@ -v expected="${snapshot#*@}" '$2 == expected { count++ } END { print count + 0 }'
)
[ "$snapshot_count" -eq "$dataset_count" ]

phase='source_preflight'
old_system=$(readlink -f /run/current-system)
base_revision=$(tr -d '\r\n' </etc/pharos/deployed-revision)
[[ "$base_revision" =~ ^[0-9a-f]{40,64}$ ]]
repo_dir="$run_dir/nixcfg"
git clone --quiet --depth 1 --branch main --single-branch "$REPO_URL" "$repo_dir" >>"$detail_log" 2>&1
target_revision=$(git -C "$repo_dir" rev-parse HEAD)
[ "$target_revision" != "$base_revision" ]
git -C "$repo_dir" fetch --quiet --depth 1 origin "$base_revision" >>"$detail_log" 2>&1
mapfile -t changed_paths < <(git -C "$repo_dir" diff --name-only "$base_revision" "$target_revision")
[ "${#changed_paths[@]}" -eq 1 ]
[ "${changed_paths[0]}" = "$PREFERENCES_PATH" ]

git -C "$repo_dir" show "$base_revision:$PREFERENCES_PATH" >"$run_dir/base-preferences.json"
cp "$repo_dir/$PREFERENCES_PATH" "$run_dir/target-preferences.json"
jq -e --arg host "$HOST" '.schema == "inspr.pharos.host-preferences.v1" and .version == 1 and .hosts[$host] != null' \
  "$run_dir/base-preferences.json" >/dev/null
jq -e --arg host "$HOST" '.schema == "inspr.pharos.host-preferences.v1" and .version == 1 and .hosts[$host] != null' \
  "$run_dir/target-preferences.json" >/dev/null
jq -S --arg host "$HOST" 'del(.hosts[$host])' "$run_dir/base-preferences.json" >"$run_dir/base-other-hosts.json"
jq -S --arg host "$HOST" 'del(.hosts[$host])' "$run_dir/target-preferences.json" >"$run_dir/target-other-hosts.json"
cmp -s "$run_dir/base-other-hosts.json" "$run_dir/target-other-hosts.json"
base_host=$(jq -cS --arg host "$HOST" '.hosts[$host]' "$run_dir/base-preferences.json")
target_host=$(jq -cS --arg host "$HOST" '.hosts[$host]' "$run_dir/target-preferences.json")
[ "$base_host" != "$target_host" ]
bash "$repo_dir/tests/T08-pharos-host-preferences.sh" >>"$detail_log" 2>&1

phase='build'
nix build --out-link "$run_dir/system" \
  "$repo_dir#nixosConfigurations.$HOST.config.system.build.toplevel" \
  >>"$detail_log" 2>&1
new_system=$(readlink -f "$run_dir/system")
[[ "$new_system" = /nix/store/* ]]
[ -x "$new_system/bin/switch-to-configuration" ]

phase='switch'
printf '%s\n' "$old_system" >"$STATE_DIR/rollback-system.tmp"
chmod 0600 "$STATE_DIR/rollback-system.tmp"
mv "$STATE_DIR/rollback-system.tmp" "$STATE_DIR/rollback-system"
switch_attempted=1
"$new_system/bin/switch-to-configuration" switch >>"$detail_log" 2>&1

phase='qa'
[ "$(tr -d '\r\n' </etc/pharos/deployed-revision)" = "$target_revision" ]
jq -e --arg host "$HOST" --slurpfile expected "$run_dir/target-preferences.json" \
  '.hosts[$host] == $expected[0].hosts[$host]' /etc/pharos/host-preferences.json >/dev/null
jq -e --arg host "$HOST" --slurpfile expected "$run_dir/target-preferences.json" \
  '.host.preferences == $expected[0].hosts[$host]' "$LIVE_MANIFEST" >/dev/null
restart_and_verify_runtime applied

phase='complete'
write_result succeeded available
printf 'host=%s action=apply status=succeeded backup=validated build=passed switch=passed beacon=accepted rollback_available=true value_returned=false\n' "$HOST"
