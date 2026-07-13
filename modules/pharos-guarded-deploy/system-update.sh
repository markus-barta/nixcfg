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
  printf 'pharos_system_update=failed failure_gate=input rollback=not_required value_returned=false\n' >&2
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
invocation_file="$action_dir/last-invocation"
stage='preflight'
switch_attempted=0
old_system=''
backup_validated=false
switch_passed=false
reboot_observed=false
kernel_verified=false
rollback_available=false
recovery_retry=false

mkdir -p "$action_dir"
chmod 0700 "$action_dir"
invocation_tmp="${invocation_file}.tmp"
printf 'phase=%s invoked_at=%s\n' "$request_phase" "$(date -u +%FT%T.%NZ)" >"$invocation_tmp"
chmod 0600 "$invocation_tmp"
mv "$invocation_tmp" "$invocation_file"
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

write_action_result() {
  local failure_gate=${1:-}
  local recovery_mode=${2:-}
  local output_path=$3

  jq -n \
    --argjson backup_validated "$backup_validated" \
    --argjson switch_passed "$switch_passed" \
    --argjson reboot_observed "$reboot_observed" \
    --argjson kernel_verified "$kernel_verified" \
    --argjson rollback_available "$rollback_available" \
    --arg failure_gate "$failure_gate" \
    --arg recovery_mode "$recovery_mode" \
    '{
      backup_validated:$backup_validated,
      switch_passed:$switch_passed,
      reboot_observed:$reboot_observed,
      kernel_verified:$kernel_verified,
      rollback_available:$rollback_available,
      failure_gate:(if $failure_gate == "" then null else $failure_gate end),
      recovery_mode:(if $recovery_mode == "" then null else $recovery_mode end)
    }' >"$output_path"
  chmod 0600 "$output_path"
}

failure_gate_for_stage() {
  case "$1" in
  input) printf '%s\n' input ;;
  preflight | source) printf '%s\n' preflight ;;
  all_host_eval | all_host_evaluation) printf '%s\n' all_host_evaluation ;;
  target_build) printf '%s\n' target_build ;;
  backup_readiness) printf '%s\n' backup_readiness ;;
  review_binding) printf '%s\n' review_binding ;;
  fresh_backup) printf '%s\n' fresh_backup ;;
  switch) printf '%s\n' switch ;;
  schedule_reboot | reboot_schedule) printf '%s\n' reboot_schedule ;;
  post_reboot_validation | reboot_timeout | boot_change) printf '%s\n' boot_change ;;
  system_identity) printf '%s\n' system_identity ;;
  revision_identity) printf '%s\n' revision_identity ;;
  kernel) printf '%s\n' kernel ;;
  rollback) printf '%s\n' rollback ;;
  storage) printf '%s\n' storage ;;
  failed_units) printf '%s\n' failed_units ;;
  required_services) printf '%s\n' required_services ;;
  heartbeat) printf '%s\n' heartbeat ;;
  *) printf '%s\n' managed_run ;;
  esac
}

write_failure() {
  local failure_gate=$1
  local null_file="$action_dir/null.json"
  local action_result_file="$action_dir/action-result.json"
  printf 'null\n' >"$null_file"
  chmod 0600 "$null_file"
  write_action_result "$failure_gate" '' "$action_result_file"
  write_public_result failed "$null_file" "$action_result_file"
}

on_error() {
  local status=$?
  local rollback='not_required'
  local failure_gate
  trap - ERR
  set +e
  failure_gate=$(failure_gate_for_stage "$stage")
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
  write_failure "$failure_gate"
  printf 'pharos_system_update=failed phase=%s failure_gate=%s rollback=%s value_returned=false\n' \
    "$request_phase" "$failure_gate" "$rollback" >&2
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
  recovery_retry=true
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

safe_revision() {
  [[ "$1" =~ ^[0-9a-f]{40,64}$ ]]
}

case "$request_phase" in
review)
  stage='preflight'
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

  stage='all_host_evaluation'
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
  backup_validated=true
  old_system=$(readlink -f /run/current-system)
  boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
  printf '%s\n' "$old_system" >"$STATE_DIR/rollback-system.tmp"
  chmod 0600 "$STATE_DIR/rollback-system.tmp"
  mv "$STATE_DIR/rollback-system.tmp" "$STATE_DIR/rollback-system"

  stage='switch'
  switch_attempted=1
  "$target_system/bin/switch-to-configuration" switch >>"$detail_log" 2>&1
  [ "$(readlink -f /run/current-system)" = "$target_system" ]
  stage='revision_identity'
  [ "$(tr -d '\r\n' </etc/pharos/deployed-revision)" = "$target_revision" ]
  switch_passed=true
  stage='kernel'
  mapfile -t configured_kernels < <(
    find -L /run/current-system/kernel-modules/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
  )
  [ "${#configured_kernels[@]}" -eq 1 ]
  [ "${configured_kernels[0]}" = "$expected_kernel" ]
  stage='failed_units'
  [ "$(systemctl --failed --no-legend | wc -l | tr -d ' ')" -eq 0 ]

  stage='reboot_schedule'
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
  stage='boot_change'
  jq -e --arg id "$action_id" --arg host "$HOST" '
    .schema == "inspr.pharos.system-update-local.v1"
    and .version == 1
    and .id == $id
    and .host == $host
    and .ticket == "PHAROS-126"
    and .status == "rebooting"
    and (.target_revision | type == "string" and test("^[0-9a-f]{40,64}$"))
    and (.target_system | type == "string" and startswith("/nix/store/"))
    and (.expected_kernel | type == "string" and length > 0 and length <= 80)
    and (.apply_snapshot | type == "string" and length > 0)
  ' "$internal_file" >/dev/null
  backup_validated=true
  switch_passed=true
  target_revision=$(jq -r '.target_revision' "$internal_file")
  target_system=$(jq -r '.target_system' "$internal_file")
  expected_kernel=$(jq -r '.expected_kernel' "$internal_file")
  previous_boot_id=$(jq -r '.boot_id_before' "$internal_file")
  current_boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
  if [ "$current_boot_id" = "$previous_boot_id" ]; then
    false
  fi
  reboot_observed=true

  stage='system_identity'
  current_system=$(readlink -f /run/current-system)
  [[ "$current_system" = /nix/store/* ]]
  [ -x "$current_system/bin/switch-to-configuration" ]
  revision_marker=$(readlink -f /etc/pharos/deployed-revision)
  [[ "$revision_marker" = /nix/store/* ]]
  [ -f "$revision_marker" ]
  nix-store --query --requisites "$current_system" >"$action_dir/current-system-requisites"
  chmod 0600 "$action_dir/current-system-requisites"
  grep -Fxq -- "$revision_marker" "$action_dir/current-system-requisites"

  stage='revision_identity'
  current_revision=$(tr -d '\r\n' </etc/pharos/deployed-revision)
  safe_revision "$current_revision"
  safe_revision "$target_revision"
  if [ "$current_system" = "$target_system" ]; then
    [ "$current_revision" = "$target_revision" ]
    recovery_mode='exact_reviewed_system'
  else
    [ "$current_revision" != "$target_revision" ]
    git -C "$repo_dir" fetch --quiet origin \
      main:refs/remotes/origin/main >>"$detail_log" 2>&1
    git -C "$repo_dir" cat-file -e "${target_revision}^{commit}"
    git -C "$repo_dir" cat-file -e "${current_revision}^{commit}"
    git -C "$repo_dir" merge-base --is-ancestor "$target_revision" "$current_revision"
    git -C "$repo_dir" merge-base --is-ancestor \
      "$current_revision" refs/remotes/origin/main
    recovery_mode='trusted_descendant'
  fi

  stage='kernel'
  mapfile -t current_kernels < <(
    find -L "$current_system/kernel-modules/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
  )
  [ "${#current_kernels[@]}" -eq 1 ]
  current_expected_kernel=${current_kernels[0]}
  safe_kernel "$expected_kernel"
  safe_kernel "$current_expected_kernel"
  [ "$(uname -r)" = "$current_expected_kernel" ]
  if [ "$recovery_mode" = exact_reviewed_system ]; then
    [ "$current_expected_kernel" = "$expected_kernel" ]
  fi
  kernel_verified=true

  stage='rollback'
  rollback_system=''
  if [ -d "$STATE_DIR/rollback-system" ]; then
    rollback_system=$(readlink -f "$STATE_DIR/rollback-system")
  elif [ -r "$STATE_DIR/rollback-system" ]; then
    rollback_system=$(tr -d '\r\n' <"$STATE_DIR/rollback-system")
  fi
  [[ "$rollback_system" = /nix/store/* ]]
  [ -x "$rollback_system/bin/switch-to-configuration" ]
  rollback_available=true

  stage='storage'
  zpool status -x "$ZFS_POOL" >"$action_dir/zpool-resume.log" 2>&1
  grep -Eq "pool '$ZFS_POOL' is healthy" "$action_dir/zpool-resume.log"

  stage='failed_units'
  [ "$(systemctl --failed --no-legend | wc -l | tr -d ' ')" -eq 0 ]

  verification_started_at=$(date -u +%FT%TZ)
  stage='required_services'
  curl --fail --silent --show-error --max-time 10 http://127.0.0.1/ >/dev/null
  [ "$(docker inspect --format '{{.State.Running}}' "$BEACON_CONTAINER" 2>/dev/null || true)" = true ]
  [ "$(docker inspect --format '{{.State.Running}}' "$HOSTDASH_CONTAINER" 2>/dev/null || true)" = true ]

  stage='heartbeat'
  beacon_ok=false
  for _ in $(seq 1 60); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$BEACON_CONTAINER" 2>/dev/null || true)" = true ] &&
      [ "$(docker inspect --format '{{.State.Running}}' "$HOSTDASH_CONTAINER" 2>/dev/null || true)" = true ] &&
      docker logs --since "$verification_started_at" "$BEACON_CONTAINER" 2>&1 |
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
  result_recovery_mode=''
  if [ "$recovery_retry" = true ]; then
    result_recovery_mode=$recovery_mode
  fi
  write_action_result '' "$result_recovery_mode" "$action_dir/action-result.json"
  printf 'null\n' >"$action_dir/null.json"
  chmod 0600 "$action_dir/null.json"
  write_public_result succeeded "$action_dir/null.json" "$action_dir/action-result.json"
  ;;
esac

trap - ERR
printf 'pharos_system_update=completed phase=%s stage=%s value_returned=false\n' \
  "$request_phase" "$stage"
