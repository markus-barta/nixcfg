#!/usr/bin/env bash
set -Eeuo pipefail

readonly HOST='@HOST@'
readonly ZFS_POOL='@ZFS_POOL@'
readonly REPO_URL='@REPO_URL@'
readonly BEACON_CONTAINER='@BEACON_CONTAINER@'
readonly HOSTDASH_CONTAINER='@HOSTDASH_CONTAINER@'
readonly STATE_DIR='@STATE_DIR@'
readonly REBOOT_TIMEOUT_SECONDS='@REBOOT_TIMEOUT_SECONDS@'
readonly REQUEST_FILE="$STATE_DIR/active-agent-request.json"

[ "$(id -u)" -eq 0 ]
[ -n "${PHAROS_DEPLOY_CAPABILITY:-}" ]
[[ "$REBOOT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]
[ "$REBOOT_TIMEOUT_SECONDS" -ge 120 ]
unset PHAROS_DEPLOY_CAPABILITY

if ! jq -e --arg host "$HOST" '
  .schema == "inspr.pharos.host-action-lease.v1"
  and .version == 1
  and .host == $host
  and .ticket == "PHAROS-126"
  and (.phase == "review" or .phase == "apply" or .phase == "resume")
  and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,159}$"))
  and (keys | sort == ["host", "id", "phase", "schema", "ticket", "version"])
' "$REQUEST_FILE" >/dev/null; then
  printf 'pharos_system_update=failed reason=invalid_local_request value_returned=false\n' >&2
  exit 1
fi

action_id=$(jq -r '.id' "$REQUEST_FILE")
request_phase=$(jq -r '.phase' "$REQUEST_FILE")
ticket=$(jq -r '.ticket' "$REQUEST_FILE")
action_dir="$STATE_DIR/actions/$action_id"
repo_dir="$action_dir/nixcfg"
internal_file="$action_dir/internal.json"
result_file="$action_dir/result.json"
detail_log="$action_dir/detail.log"
stage='preflight'
switch_attempted=0
old_system=''

mkdir -p "$action_dir"
chmod 0700 "$action_dir"
touch "$detail_log"
chmod 0600 "$detail_log"
exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || {
  printf 'pharos_system_update=blocked reason=deployment_in_progress value_returned=false\n' >&2
  exit 1
}

write_public_result() {
  local outcome=$1
  local plan_path=$2
  local action_result_path=$3
  local tmp="${result_file}.tmp"

  jq -n \
    --arg host "$HOST" \
    --arg phase "$request_phase" \
    --arg outcome "$outcome" \
    --slurpfile plan "$plan_path" \
    --slurpfile action_result "$action_result_path" \
    '{
      schema:"inspr.pharos.host-action-agent-result.v1",
      version:1,
      host:$host,
      phase:$phase,
      outcome:$outcome,
      plan:($plan[0] // null),
      result:($action_result[0] // null)
    }' >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$result_file"
}

write_failure() {
  local null_file="$action_dir/null.json"
  printf 'null\n' >"$null_file"
  chmod 0600 "$null_file"
  write_public_result failed "$null_file" "$null_file"
}

on_error() {
  local status=$?
  local rollback='not_required'
  trap - ERR
  set +e
  if [ "$switch_attempted" -eq 1 ] && [ -n "$old_system" ] && [ -x "$old_system/bin/switch-to-configuration" ]; then
    if [ "$(readlink -f /run/current-system)" = "$old_system" ]; then
      rollback='not_required'
    else
      rollback='failed'
      if "$old_system/bin/switch-to-configuration" switch >>"$detail_log" 2>&1 &&
        [ "$(readlink -f /run/current-system)" = "$old_system" ]; then
        rollback='succeeded'
      fi
    fi
  fi
  write_failure
  printf 'pharos_system_update=failed phase=%s stage=%s rollback=%s value_returned=false\n' \
    "$request_phase" "$stage" "$rollback" >&2
  exit "$status"
}
trap on_error ERR

if [ -f "$result_file" ] && jq -e --arg phase "$request_phase" '
  .schema == "inspr.pharos.host-action-agent-result.v1"
  and .phase == $phase
  and (.outcome == "succeeded" or .outcome == "rebooting")
' \
  "$result_file" >/dev/null 2>&1; then
  printf 'pharos_system_update=idempotent phase=%s value_returned=false\n' "$request_phase"
  exit 0
fi
if [ -f "$result_file" ] && jq -e --arg phase "$request_phase" '
  .schema == "inspr.pharos.host-action-agent-result.v1"
  and .phase == $phase
  and .outcome == "failed"
' "$result_file" >/dev/null 2>&1; then
  printf 'pharos_system_update=recovery_retry phase=%s value_returned=false\n' "$request_phase"
fi

validated_snapshot() {
  local label=$1
  local snapshot
  local dataset_count
  local snapshot_count

  zpool status -x "$ZFS_POOL" >"$action_dir/zpool-$label.log" 2>&1
  grep -Eq "pool '$ZFS_POOL' is healthy" "$action_dir/zpool-$label.log"
  snapshot="$ZFS_POOL@pharos-$label-$(date -u +%Y%m%dT%H%M%SZ)"
  dataset_count=$(zfs list -H -r -o name "$ZFS_POOL" | wc -l | tr -d ' ')
  [ "$dataset_count" -gt 0 ]
  zfs snapshot -r "$snapshot" >>"$detail_log" 2>&1
  snapshot_count=$(
    zfs list -H -t snapshot -r -o name "$ZFS_POOL" |
      awk -F@ -v expected="${snapshot#*@}" '$2 == expected { count++ } END { print count + 0 }'
  )
  [ "$snapshot_count" -eq "$dataset_count" ]
  printf '%s\n' "$snapshot"
}

safe_kernel() {
  [[ "$1" =~ ^[A-Za-z0-9._+-]{1,80}$ ]]
}

case "$request_phase" in
review)
  stage='source'
  [ ! -e "$repo_dir" ]
  git clone --quiet --branch main --single-branch "$REPO_URL" "$repo_dir" >>"$detail_log" 2>&1
  target_revision=$(git -C "$repo_dir" rev-parse HEAD)
  [[ "$target_revision" =~ ^[0-9a-f]{40,64}$ ]]

  base_revision=''
  if [ -r /etc/pharos/deployed-revision ]; then
    candidate=$(tr -d '\r\n' </etc/pharos/deployed-revision)
    if [[ "$candidate" =~ ^[0-9a-f]{40,64}$ ]]; then
      base_revision=$candidate
    fi
  fi

  changed_paths="$action_dir/changed-paths"
  changed_areas="$action_dir/changed-areas"
  if [ -n "$base_revision" ]; then
    git -C "$repo_dir" fetch --quiet origin "$base_revision" >>"$detail_log" 2>&1
    git -C "$repo_dir" diff --name-only "$base_revision" "$target_revision" >"$changed_paths"
    while IFS= read -r path; do
      case "$path" in
      flake.lock) printf '%s\n' 'flake.lock' ;;
      hosts/"$HOST"/*) printf '%s\n' 'host-config' ;;
      hosts/csb1/docker/pharos/manifests/*) printf '%s\n' 'manifest' ;;
      modules/*) printf '%s\n' 'modules' ;;
      .github/* | scripts/* | tests/*) printf '%s\n' 'automation' ;;
      *) printf '%s\n' 'nixcfg' ;;
      esac
    done <"$changed_paths" | LC_ALL=C sort -u >"$changed_areas"
  else
    printf '%s\n' 'baseline-unavailable' 'system' >"$changed_areas"
    printf '%s\n' 'baseline-unavailable' >"$changed_paths"
  fi
  changed_file_count=$(wc -l <"$changed_paths" | tr -d ' ')
  [ "$changed_file_count" -le 10000 ]
  [ "$(wc -l <"$changed_areas" | tr -d ' ')" -le 24 ]
  grep -Eq '^[a-z0-9._-]+$' "$changed_areas" || [ ! -s "$changed_areas" ]

  stage='all_host_eval'
  nix eval --no-update-lock-file --json \
    "$repo_dir#nixosConfigurations" \
    --apply 'configs: builtins.attrNames configs' \
    >"$action_dir/hosts.json" 2>>"$detail_log"
  jq -e 'type == "array" and length > 0 and all(.[]; test("^[a-z0-9-]+$"))' \
    "$action_dir/hosts.json" >/dev/null
  jq -r '.[]' "$action_dir/hosts.json" | LC_ALL=C sort -u >"$action_dir/hosts"
  while IFS= read -r host; do
    nix eval --no-update-lock-file \
      "$repo_dir#nixosConfigurations.$host.config.system.build.toplevel.drvPath" \
      >>"$detail_log" 2>&1
  done <"$action_dir/hosts"

  stage='target_build'
  nix build --out-link "$action_dir/system" \
    "$repo_dir#nixosConfigurations.$HOST.config.system.build.toplevel" \
    >>"$detail_log" 2>&1
  target_system=$(readlink -f "$action_dir/system")
  [[ "$target_system" = /nix/store/* ]]
  [ -x "$target_system/bin/switch-to-configuration" ]
  mapfile -t expected_kernels < <(
    find -L "$target_system/kernel-modules/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
  )
  [ "${#expected_kernels[@]}" -eq 1 ]
  expected_kernel=${expected_kernels[0]}
  running_kernel=$(uname -r)
  safe_kernel "$expected_kernel"
  safe_kernel "$running_kernel"

  stage='backup_readiness'
  review_snapshot=$(validated_snapshot review)
  boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)

  internal_tmp="${internal_file}.tmp"
  jq -n \
    --arg id "$action_id" \
    --arg host "$HOST" \
    --arg ticket "$ticket" \
    --arg target_revision "$target_revision" \
    --arg base_revision "$base_revision" \
    --arg target_system "$target_system" \
    --arg expected_kernel "$expected_kernel" \
    --arg running_kernel "$running_kernel" \
    --arg review_snapshot "$review_snapshot" \
    --arg boot_id "$boot_id" \
    --arg reviewed_at "$(date -u +%FT%TZ)" \
    '{
      schema:"inspr.pharos.system-update-local.v1",
      version:1,
      id:$id,
      host:$host,
      ticket:$ticket,
      status:"reviewed",
      target_revision:$target_revision,
      base_revision:$base_revision,
      target_system:$target_system,
      expected_kernel:$expected_kernel,
      running_kernel:$running_kernel,
      review_snapshot:$review_snapshot,
      boot_id_before:$boot_id,
      reviewed_at:$reviewed_at
    }' >"$internal_tmp"
  chmod 0600 "$internal_tmp"
  mv "$internal_tmp" "$internal_file"

  jq -Rsc 'split("\n") | map(select(length > 0))' "$changed_areas" >"$action_dir/areas.json"
  jq -n \
    --argjson changed_file_count "$changed_file_count" \
    --slurpfile areas "$action_dir/areas.json" \
    --arg running_kernel "$running_kernel" \
    --arg expected_kernel "$expected_kernel" \
    '{
      changed_file_count:$changed_file_count,
      changed_areas:$areas[0],
      all_host_eval_passed:true,
      target_build_passed:true,
      backup_ready:true,
      running_kernel:$running_kernel,
      expected_kernel:$expected_kernel,
      restart_required:true
    }' >"$action_dir/plan.json"
  printf 'null\n' >"$action_dir/null.json"
  chmod 0600 "$action_dir/plan.json" "$action_dir/null.json"
  write_public_result succeeded "$action_dir/plan.json" "$action_dir/null.json"
  ;;

apply)
  stage='review_binding'
  jq -e --arg id "$action_id" --arg host "$HOST" '
    .schema == "inspr.pharos.system-update-local.v1"
    and .version == 1
    and .id == $id
    and .host == $host
    and .ticket == "PHAROS-126"
    and .status == "reviewed"
  ' "$internal_file" >/dev/null
  target_revision=$(jq -r '.target_revision' "$internal_file")
  target_system=$(jq -r '.target_system' "$internal_file")
  expected_kernel=$(jq -r '.expected_kernel' "$internal_file")
  [ "$(git -C "$repo_dir" rev-parse HEAD)" = "$target_revision" ]
  [ "$(readlink -f "$action_dir/system")" = "$target_system" ]
  [ -x "$target_system/bin/switch-to-configuration" ]
  safe_kernel "$expected_kernel"

  stage='fresh_backup'
  apply_snapshot=$(validated_snapshot preswitch)
  old_system=$(readlink -f /run/current-system)
  boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
  printf '%s\n' "$old_system" >"$STATE_DIR/rollback-system.tmp"
  chmod 0600 "$STATE_DIR/rollback-system.tmp"
  mv "$STATE_DIR/rollback-system.tmp" "$STATE_DIR/rollback-system"

  stage='switch'
  switch_attempted=1
  "$target_system/bin/switch-to-configuration" switch >>"$detail_log" 2>&1
  [ "$(readlink -f /run/current-system)" = "$target_system" ]
  [ "$(tr -d '\r\n' </etc/pharos/deployed-revision)" = "$target_revision" ]
  mapfile -t configured_kernels < <(
    find -L /run/current-system/kernel-modules/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
  )
  [ "${#configured_kernels[@]}" -eq 1 ]
  [ "${configured_kernels[0]}" = "$expected_kernel" ]
  [ "$(systemctl --failed --no-legend | wc -l | tr -d ' ')" -eq 0 ]

  stage='schedule_reboot'
  switched_at=$(date -u +%FT%TZ)
  reboot_deadline_epoch=$(($(date -u +%s) + REBOOT_TIMEOUT_SECONDS))
  internal_tmp="${internal_file}.tmp"
  jq \
    --arg status rebooting \
    --arg old_system "$old_system" \
    --arg apply_snapshot "$apply_snapshot" \
    --arg boot_id "$boot_id" \
    --arg switched_at "$switched_at" \
    --argjson reboot_deadline_epoch "$reboot_deadline_epoch" \
    '.status=$status | .old_system=$old_system | .apply_snapshot=$apply_snapshot | .boot_id_before=$boot_id | .switched_at=$switched_at | .reboot_deadline_epoch=$reboot_deadline_epoch' \
    "$internal_file" >"$internal_tmp"
  chmod 0600 "$internal_tmp"
  mv "$internal_tmp" "$internal_file"
  printf 'null\n' >"$action_dir/null.json"
  chmod 0600 "$action_dir/null.json"
  write_public_result rebooting "$action_dir/null.json" "$action_dir/null.json"
  systemd-run \
    --unit="pharos-guarded-reboot-$(date -u +%s)" \
    --on-active=45s \
    --property=Type=oneshot \
    /run/current-system/sw/bin/systemctl reboot >>"$detail_log" 2>&1
  switch_attempted=0
  ;;

resume)
  stage='post_reboot_validation'
  jq -e --arg id "$action_id" --arg host "$HOST" '
    .schema == "inspr.pharos.system-update-local.v1"
    and .version == 1
    and .id == $id
    and .host == $host
    and .ticket == "PHAROS-126"
    and .status == "rebooting"
  ' "$internal_file" >/dev/null
  target_revision=$(jq -r '.target_revision' "$internal_file")
  target_system=$(jq -r '.target_system' "$internal_file")
  expected_kernel=$(jq -r '.expected_kernel' "$internal_file")
  previous_boot_id=$(jq -r '.boot_id_before' "$internal_file")
  current_boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
  if [ "$current_boot_id" = "$previous_boot_id" ]; then
    stage='reboot_timeout'
    false
  fi
  [ "$(readlink -f /run/current-system)" = "$target_system" ]
  [ "$(tr -d '\r\n' </etc/pharos/deployed-revision)" = "$target_revision" ]
  [ "$(uname -r)" = "$expected_kernel" ]
  [ -x "$STATE_DIR/rollback-system/bin/switch-to-configuration" ] ||
    [ -x "$(tr -d '\r\n' <"$STATE_DIR/rollback-system")/bin/switch-to-configuration" ]
  zpool status -x "$ZFS_POOL" >"$action_dir/zpool-resume.log" 2>&1
  grep -Eq "pool '$ZFS_POOL' is healthy" "$action_dir/zpool-resume.log"
  [ "$(systemctl --failed --no-legend | wc -l | tr -d ' ')" -eq 0 ]
  curl --fail --silent --show-error --max-time 10 http://127.0.0.1/ >/dev/null

  boot_epoch=$(awk '$1 == "btime" { print $2 }' /proc/stat)
  boot_time=$(date -u -d "@$boot_epoch" +%FT%TZ)
  beacon_ok=false
  for _ in $(seq 1 60); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$BEACON_CONTAINER" 2>/dev/null || true)" = true ] &&
      [ "$(docker inspect --format '{{.State.Running}}' "$HOSTDASH_CONTAINER" 2>/dev/null || true)" = true ] &&
      docker logs --since "$boot_time" "$BEACON_CONTAINER" 2>&1 |
      grep -Eq "reported $HOST .*HTTP (200|204)"; then
      beacon_ok=true
      break
    fi
    sleep 3
  done
  [ "$beacon_ok" = true ]

  internal_tmp="${internal_file}.tmp"
  jq --arg status succeeded --arg completed_at "$(date -u +%FT%TZ)" \
    '.status=$status | .completed_at=$completed_at' "$internal_file" >"$internal_tmp"
  chmod 0600 "$internal_tmp"
  mv "$internal_tmp" "$internal_file"
  jq -n '{
    backup_validated:true,
    switch_passed:true,
    reboot_observed:true,
    kernel_verified:true,
    rollback_available:true
  }' >"$action_dir/action-result.json"
  printf 'null\n' >"$action_dir/null.json"
  chmod 0600 "$action_dir/action-result.json" "$action_dir/null.json"
  write_public_result succeeded "$action_dir/null.json" "$action_dir/action-result.json"
  ;;
esac

trap - ERR
printf 'pharos_system_update=completed phase=%s stage=%s value_returned=false\n' \
  "$request_phase" "$stage"
