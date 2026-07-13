#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/pharos-guarded-deploy/default.nix"
agent_source="$repo_root/modules/pharos-guarded-deploy/action-agent.sh"
runner="$repo_root/modules/pharos-guarded-deploy/system-update.sh"
review="$repo_root/modules/pharos-guarded-deploy/review.sh"
host_config="$repo_root/hosts/hsb8/configuration.nix"
common="$repo_root/modules/common.nix"

bash -n "$agent_source" "$runner" "$review"
[ "$(grep -Fc 'allowed_args = []' "$module")" -eq 3 ]
# These assertions intentionally match literal Nix and shell interpolation syntax.
# shellcheck disable=SC2016
grep -Fq 'id = "profile.${updateSecretName}"' "$module"
# shellcheck disable=SC2016
grep -Fq 'binary = "${systemUpdateRunner}/bin/pharos-guarded-system-update"' "$module"
grep -Fq 'EnvironmentFile = cfg.tokenEnvironmentFile;' "$module"
grep -Fq 'restartIfChanged = false;' "$module"
# shellcheck disable=SC2016
grep -Fq 'OnUnitActiveSec = "${toString cfg.actionPollSeconds}s";' "$module"
grep -Fq 'unset PHAROS_TOKEN' "$agent_source"
# shellcheck disable=SC2016
grep -Fq -- '--config "$auth_config"' "$agent_source"
grep -Fq 'system.configurationRevision = inputs.self.rev or null;' "$common"
grep -Fq 'mode = "janus";' "$host_config"
grep -Fq 'janusRequired = true;' "$host_config"
grep -Fq 'hsb8DockerCompose = pkgs.writeText' "$host_config"
grep -Fq 'restartTriggers = [ hsb8DockerCompose ];' "$host_config"
# shellcheck disable=SC2016
grep -Fq '${hsb8DockerCompose} up -d' "$host_config"
if grep -Fq '/home/mba/Code/nixcfg/hosts/hsb8/docker/docker-compose.yml up -d' "$host_config"; then
  echo 'hsb8 stack still reads compose from a mutable checkout' >&2
  exit 1
fi

if grep -Eq 'curl .*PHAROS_TOKEN|Authorization: Bearer.*--header|PHAROS_TOKEN=.*curl' "$agent_source"; then
  echo 'beacon token can reach curl arguments' >&2
  exit 1
fi

review_eval_line=$(grep -n "stage='all_host_evaluation'" "$runner" | cut -d: -f1)
review_build_line=$(grep -n "stage='target_build'" "$runner" | cut -d: -f1)
review_backup_line=$(grep -n "stage='backup_readiness'" "$runner" | cut -d: -f1)
apply_backup_line=$(grep -n "stage='fresh_backup'" "$runner" | cut -d: -f1)
apply_switch_line=$(grep -n "stage='switch'" "$runner" | cut -d: -f1)
apply_reboot_line=$(grep -n "stage='reboot_schedule'" "$runner" | cut -d: -f1)
[ "$review_eval_line" -lt "$review_build_line" ]
[ "$review_build_line" -lt "$review_backup_line" ]
[ "$apply_backup_line" -lt "$apply_switch_line" ]
[ "$apply_switch_line" -lt "$apply_reboot_line" ]
grep -Fq 'write_public_result rebooting' "$runner"
grep -Fq 'reboot_observed=true' "$runner"
grep -Fq 'kernel_verified=true' "$runner"
grep -Fq 'rollback_available=true' "$runner"
grep -Fq 'pharos_action_agent=deferred reason=waiting_for_reboot' "$agent_source"
grep -Fq 'pharos_action_agent=timeout reason=reboot_not_observed' "$agent_source"
grep -Fq 'pharos_system_update=recovery_retry phase=%s value_returned=false' "$runner"
grep -Fq '(.outcome == "succeeded" or .outcome == "rebooting")' "$runner"
grep -Fq 'recovery_mode='"'"'trusted_descendant'"'"'' "$runner"
# shellcheck disable=SC2016
grep -Fq 'merge-base --is-ancestor "$target_revision" "$current_revision"' "$runner"
# shellcheck disable=SC2016
grep -Fq '"$current_revision" refs/remotes/origin/main' "$runner"
# shellcheck disable=SC2016
grep -Fq 'grep -Fxq -- "$revision_marker" "$action_dir/current-system-requisites"' "$runner"
# shellcheck disable=SC2016
grep -Fq 'failure_gate:(if $failure_gate == "" then null else $failure_gate end)' "$runner"
grep -Fq 'exit_success=true exit_code=Some\(0\) reason_code=ok value_returned=false' "$review"
grep -Fq 'failure_gate=%s value_returned=false' "$review"
grep -Fq "stat -c '%d:%i:%Y:%s'" "$agent_source"
grep -Fq "stat -f '%d:%i:%m:%z'" "$agent_source"

fixture_root=$(mktemp -d)
trap 'rm -r "$fixture_root"' EXIT
state_dir="$fixture_root/state"
fake_bin="$fixture_root/bin"
fake_guard="$fixture_root/pharos-guarded-deploy"
agent="$fixture_root/pharos-host-action-agent"
boot_id_file="$fixture_root/boot-id"
mkdir -p "$state_dir" "$fake_bin"
printf 'boot-current\n' >"$boot_id_file"

sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$agent"
chmod +x "$agent"

cat >"$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = -u ]; then
  printf '0\n'
else
  exit 1
fi
EOF

cat >"$fake_bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/shred" <<'EOF'
#!/usr/bin/env bash
for path in "$@"; do
  case "$path" in
  -*) continue ;;
  esac
  [ ! -e "$path" ] || rm -f "$path"
done
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=''
body=''
config=''
url=''
args="$*"
while [ "$#" -gt 0 ]; do
  case "$1" in
  --output)
    output=$2
    shift 2
    ;;
  --data-binary)
    body=${2#@}
    shift 2
    ;;
  --config)
    config=$2
    shift 2
    ;;
  http://*)
    url=$1
    shift
    ;;
  *) shift ;;
  esac
done

[ -z "${PHAROS_TOKEN:-}" ] || printf '%s\n' token-env-leak >"$FAKE_LEAK_LOG"
grep -Fq "$FAKE_TOKEN" "$config"
printf '%s\n' "$args" >>"$FAKE_ARG_LOG"

if [ "${FAKE_CURL_UNREACHABLE:-0}" = 1 ]; then
  exit 28
fi

case "$url" in
*/agent/actions/claim)
  if [ "${FAKE_CLAIM_ONCE:-0}" = 1 ]; then
    [ -n "${FAKE_CLAIM_COUNT_FILE:-}" ]
    claim_count=0
    if [ -r "$FAKE_CLAIM_COUNT_FILE" ]; then
      claim_count=$(<"$FAKE_CLAIM_COUNT_FILE")
    fi
    claim_count=$((claim_count + 1))
    printf '%s\n' "$claim_count" >"$FAKE_CLAIM_COUNT_FILE"
    if [ "$claim_count" -gt 1 ]; then
      : >"$output"
      printf '204'
      exit 0
    fi
  fi
  jq -n \
    --arg id "${FAKE_CLAIM_ID:-action-update-restart-hsb8-100-1}" \
    --arg phase "${FAKE_CLAIM_PHASE:-review}" \
    '{
      schema:"inspr.pharos.host-action-lease.v1",
      version:1,
      id:$id,
      host:"hsb8",
      ticket:"PHAROS-126",
      phase:$phase
    }' >"$output"
  printf '200'
  ;;
*/result)
  cp "$body" "$FAKE_POST_BODY"
  printf '{}\n' >"$output"
  printf '200'
  ;;
*) exit 1 ;;
esac
EOF

cat >"$fake_guard" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = update ]
[ "$2" = PHAROS-126 ]
[ -z "${PHAROS_TOKEN:-}" ] || printf '%s\n' token-env-leak >"$FAKE_LEAK_LOG"
if [ "${FAKE_GUARD_FAIL:-0}" = 1 ]; then
  printf 'pharos_guarded_deploy=failed action=update stage=approval failure_gate=approval value_returned=false\n' >&2
  exit 1
fi
request="$FAKE_STATE_DIR/active-agent-request.json"
action_id=$(jq -r '.id' "$request")
phase=$(jq -r '.phase' "$request")
printf '%s %s %s\n' "$1" "$2" "$phase" >>"$FAKE_GUARD_LOG"
action_dir="$FAKE_STATE_DIR/actions/$action_id"
mkdir -p "$action_dir"
if [ "${FAKE_GUARD_IDEMPOTENT:-0}" = 1 ]; then
  printf 'phase=%s invoked_at=fixture\n' "$phase" >"$action_dir/last-invocation.tmp"
  mv "$action_dir/last-invocation.tmp" "$action_dir/last-invocation"
  printf 'pharos_system_update=idempotent phase=%s value_returned=false\n' "$phase"
  exit 0
fi
if [ "${FAKE_GUARD_TYPED_FAIL:-0}" = 1 ]; then
  printf 'phase=%s invoked_at=fixture\n' "$phase" >"$action_dir/last-invocation.tmp"
  mv "$action_dir/last-invocation.tmp" "$action_dir/last-invocation"
  jq -n --arg phase "$phase" '{
    schema:"inspr.pharos.host-action-agent-result.v1",
    version:1,
    host:"hsb8",
    phase:$phase,
    outcome:"failed",
    plan:null,
    result:{
      backup_validated:true,
      switch_passed:true,
      reboot_observed:true,
      kernel_verified:true,
      rollback_available:true,
      failure_gate:"heartbeat",
      recovery_mode:null
    }
  }' >"$action_dir/result.json.tmp"
  mv "$action_dir/result.json.tmp" "$action_dir/result.json"
  printf 'pharos_guarded_deploy=failed action=update stage=managed_run failure_gate=heartbeat value_returned=false\n' >&2
  exit 1
fi
if [ "$phase" = resume ]; then
  printf 'phase=resume invoked_at=fixture\n' >"$action_dir/last-invocation.tmp"
  mv "$action_dir/last-invocation.tmp" "$action_dir/last-invocation"
  if [ "${FAKE_GUARD_RESUME_TIMEOUT:-0}" = 1 ]; then
    jq -n '{
      schema:"inspr.pharos.host-action-agent-result.v1",
      version:1,
      host:"hsb8",
      phase:"resume",
      outcome:"failed",
      plan:null,
      result:{
        backup_validated:true,
        switch_passed:true,
        reboot_observed:false,
        kernel_verified:false,
        rollback_available:false,
        failure_gate:"boot_change",
        recovery_mode:null
      }
    }' >"$action_dir/result.json.tmp"
    mv "$action_dir/result.json.tmp" "$action_dir/result.json"
    printf 'pharos_guarded_deploy=failed action=update stage=managed_run failure_gate=boot_change value_returned=false\n' >&2
    exit 1
  fi
  if [ -f "$action_dir/internal.json" ]; then
    jq '.status = "succeeded"' "$action_dir/internal.json" >"$action_dir/internal.json.tmp"
    mv "$action_dir/internal.json.tmp" "$action_dir/internal.json"
  fi
  jq -n '{
    schema:"inspr.pharos.host-action-agent-result.v1",
    version:1,
    host:"hsb8",
    phase:"resume",
    outcome:"succeeded",
    plan:null,
    result:{
      backup_validated:true,
      switch_passed:true,
      reboot_observed:true,
      kernel_verified:true,
      rollback_available:true,
      failure_gate:null,
      recovery_mode:null
    }
  }' >"$action_dir/result.json"
  chmod 0600 "$action_dir/result.json"
  exit 0
fi
jq -n --arg phase "$phase" '{
  schema:"inspr.pharos.host-action-agent-result.v1",
  version:1,
  host:"hsb8",
  phase:$phase,
  outcome:"succeeded",
  plan:{
    changed_file_count:1,
    changed_areas:["host-config"],
    all_host_eval_passed:true,
    target_build_passed:true,
    backup_ready:true,
    running_kernel:"7.0.13",
    expected_kernel:"7.0.14",
    restart_required:true
  },
  result:null
}' >"$action_dir/result.json"
chmod 0600 "$action_dir/result.json"
EOF

chmod +x "$fake_bin/id" "$fake_bin/flock" "$fake_bin/shred" "$fake_bin/curl" "$fake_guard"

token='test-token-never-rendered-123456'
arg_log="$fixture_root/curl-args"
leak_log="$fixture_root/leak"
post_body="$fixture_root/post-body.json"
guard_log="$fixture_root/guard-log"
output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$state_dir" \
    "$agent" 2>&1
)

grep -Fq 'pharos_action_agent=reported phase=review outcome=succeeded runner_ok=true' <<<"$output"
grep -Fxq 'update PHAROS-126 review' "$guard_log"
jq -e '
  .host == "hsb8"
  and .phase == "review"
  and .outcome == "succeeded"
  and .plan.backup_ready == true
  and .result == null
' "$post_body" >/dev/null
[ ! -e "$state_dir/active-agent-request.json" ]
[ ! -e "$leak_log" ]
if grep -Fq "$token" "$arg_log" || grep -Fq "$token" <<<"$output" || grep -Fq "$token" "$post_body"; then
  echo 'beacon token escaped the private curl config' >&2
  exit 1
fi

idempotent_state_dir="$fixture_root/idempotent-state"
idempotent_action_dir="$idempotent_state_dir/actions/action-update-restart-hsb8-100-1"
idempotent_post_body="$fixture_root/idempotent-post-body.json"
idempotent_agent="$fixture_root/pharos-host-action-agent-idempotent"
mkdir -p "$idempotent_action_dir"
printf 'phase=review invoked_at=old-fixture\n' >"$idempotent_action_dir/last-invocation"
jq -n '{
  schema:"inspr.pharos.host-action-agent-result.v1",
  version:1,
  host:"hsb8",
  phase:"review",
  outcome:"succeeded",
  plan:{
    changed_file_count:1,
    changed_areas:["host-config"],
    all_host_eval_passed:true,
    target_build_passed:true,
    backup_ready:true,
    running_kernel:"7.0.13",
    expected_kernel:"7.0.14",
    restart_required:true
  },
  result:null
}' >"$idempotent_action_dir/result.json"
sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$idempotent_state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$idempotent_agent"
chmod +x "$idempotent_agent"
idempotent_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$idempotent_post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$idempotent_state_dir" \
    FAKE_GUARD_IDEMPOTENT=1 \
    "$idempotent_agent" 2>&1
)
grep -Fq 'pharos_action_agent=reported phase=review outcome=succeeded runner_ok=true' \
  <<<"$idempotent_output"
jq -e '.phase == "review" and .outcome == "succeeded" and .plan.backup_ready == true' \
  "$idempotent_post_body" >/dev/null

typed_failure_state_dir="$fixture_root/typed-failure-state"
typed_failure_post_body="$fixture_root/typed-failure-post-body.json"
typed_failure_agent="$fixture_root/pharos-host-action-agent-typed-failure"
mkdir -p "$typed_failure_state_dir"
sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$typed_failure_state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$typed_failure_agent"
chmod +x "$typed_failure_agent"
typed_failure_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$typed_failure_post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$typed_failure_state_dir" \
    FAKE_GUARD_TYPED_FAIL=1 \
    "$typed_failure_agent" 2>&1
)
grep -Fq 'pharos_action_agent=reported phase=review outcome=failed runner_ok=false' \
  <<<"$typed_failure_output"
jq -e '
  .phase == "review"
  and .outcome == "failed"
  and .result.backup_validated == true
  and .result.switch_passed == true
  and .result.reboot_observed == true
  and .result.kernel_verified == true
  and .result.rollback_available == true
  and .result.failure_gate == "heartbeat"
' "$typed_failure_post_body" >/dev/null

deferred_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$state_dir" \
    FAKE_CURL_UNREACHABLE=1 \
    "$agent" 2>&1
)
grep -Fq 'pharos_action_agent=deferred reason=claim_unreachable' <<<"$deferred_output"
[ ! -e "$leak_log" ]
if grep -Fq "$token" <<<"$deferred_output"; then
  echo 'beacon token escaped the deferred path' >&2
  exit 1
fi

failure_state_dir="$fixture_root/failure-state"
failure_post_body="$fixture_root/failure-post-body.json"
failure_agent="$fixture_root/pharos-host-action-agent-failure"
mkdir -p "$failure_state_dir"
failure_action_dir="$failure_state_dir/actions/action-update-restart-hsb8-100-1"
mkdir -p "$failure_action_dir"
jq -n '{
  schema:"inspr.pharos.host-action-agent-result.v1",
  version:1,
  host:"hsb8",
  phase:"review",
  outcome:"failed",
  plan:null,
  result:{
    backup_validated:true,
    switch_passed:true,
    reboot_observed:false,
    kernel_verified:false,
    rollback_available:true,
    failure_gate:"switch",
    recovery_mode:null
  }
}' >"$failure_action_dir/result.json"
sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$failure_state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$failure_agent"
chmod +x "$failure_agent"
failure_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$failure_post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$failure_state_dir" \
    FAKE_GUARD_FAIL=1 \
    "$failure_agent" 2>&1
)
grep -Fq \
  'pharos_guarded_deploy=failed action=update stage=approval failure_gate=approval value_returned=false' \
  <<<"$failure_output"
grep -Fq 'pharos_action_agent=reported phase=review outcome=failed runner_ok=false' \
  <<<"$failure_output"
jq -e '
  .phase == "review"
  and .outcome == "failed"
  and .plan == null
  and .result.backup_validated == false
  and .result.switch_passed == false
  and .result.reboot_observed == false
  and .result.kernel_verified == false
  and .result.rollback_available == false
  and .result.failure_gate == "approval"
  and .result.recovery_mode == null
' \
  "$failure_post_body" >/dev/null
[ ! -e "$leak_log" ]
if grep -Fq "$token" <<<"$failure_output" || grep -Fq "$token" "$failure_post_body"; then
  echo 'beacon token escaped the guarded failure path' >&2
  exit 1
fi

waiting_state_dir="$fixture_root/waiting-state"
waiting_agent="$fixture_root/pharos-host-action-agent-waiting"
waiting_arg_log="$fixture_root/waiting-curl-args"
waiting_post_body="$fixture_root/waiting-post-body.json"
waiting_guard_log="$fixture_root/waiting-guard-log"
waiting_claim_count="$fixture_root/waiting-claim-count"
waiting_action_dir="$waiting_state_dir/actions/action-update-restart-hsb8-waiting"
mkdir -p "$waiting_action_dir"
cat >"$waiting_action_dir/internal.json" <<'JSON'
{
  "schema": "inspr.pharos.system-update-local.v1",
  "version": 1,
  "id": "action-update-restart-hsb8-waiting",
  "host": "hsb8",
  "ticket": "PHAROS-126",
  "status": "rebooting",
  "boot_id_before": "boot-current",
  "switched_at": "2026-07-13T05:04:32Z",
  "reboot_deadline_epoch": 4102444800
}
JSON
sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$waiting_state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$waiting_agent"
chmod +x "$waiting_agent"

# Each invocation is a fresh process. Reusing the state directory exercises
# timer/service restart persistence without relying on process memory.
for _ in 1 2; do
  waiting_output=$(
    PATH="$fake_bin:$PATH" \
      PHAROS_TOKEN="$token" \
      FAKE_TOKEN="$token" \
      FAKE_ARG_LOG="$waiting_arg_log" \
      FAKE_LEAK_LOG="$leak_log" \
      FAKE_POST_BODY="$waiting_post_body" \
      FAKE_GUARD_LOG="$waiting_guard_log" \
      FAKE_STATE_DIR="$waiting_state_dir" \
      "$waiting_agent" 2>&1
  )
  grep -Fxq 'pharos_action_agent=deferred reason=waiting_for_reboot' <<<"$waiting_output"
done
[ ! -e "$waiting_arg_log" ]
jq -e '.status == "rebooting" and .boot_id_before == "boot-current"' \
  "$waiting_action_dir/internal.json" >/dev/null

printf 'boot-new\n' >"$boot_id_file"
post_boot_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$waiting_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$waiting_post_body" \
    FAKE_GUARD_LOG="$waiting_guard_log" \
    FAKE_STATE_DIR="$waiting_state_dir" \
    FAKE_CLAIM_PHASE=resume \
    FAKE_CLAIM_ID=action-update-restart-hsb8-waiting \
    FAKE_CLAIM_ONCE=1 \
    FAKE_CLAIM_COUNT_FILE="$waiting_claim_count" \
    "$waiting_agent" 2>&1
)
grep -Fxq 'pharos_action_agent=reported phase=resume outcome=succeeded runner_ok=true' \
  <<<"$post_boot_output"
[ -s "$waiting_arg_log" ]
jq -e '
  .phase == "resume"
  and .outcome == "succeeded"
  and .plan == null
  and .result.backup_validated == true
  and .result.switch_passed == true
  and .result.reboot_observed == true
  and .result.kernel_verified == true
  and .result.rollback_available == true
  and .result.failure_gate == null
' "$waiting_post_body" >/dev/null
jq -e '.status == "succeeded"' "$waiting_action_dir/internal.json" >/dev/null
[ "$(grep -Fc 'update PHAROS-126 resume' "$waiting_guard_log")" -eq 1 ]

duplicate_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$waiting_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$waiting_post_body" \
    FAKE_GUARD_LOG="$waiting_guard_log" \
    FAKE_STATE_DIR="$waiting_state_dir" \
    FAKE_CLAIM_PHASE=resume \
    FAKE_CLAIM_ID=action-update-restart-hsb8-waiting \
    FAKE_CLAIM_ONCE=1 \
    FAKE_CLAIM_COUNT_FILE="$waiting_claim_count" \
    "$waiting_agent" 2>&1
)
grep -Fxq 'pharos_action_agent=idle' <<<"$duplicate_output"
[ "$(<"$waiting_claim_count")" -eq 2 ]
[ "$(grep -Fc 'update PHAROS-126 resume' "$waiting_guard_log")" -eq 1 ]

printf 'boot-current\n' >"$boot_id_file"
timeout_state_dir="$fixture_root/timeout-state"
timeout_agent="$fixture_root/pharos-host-action-agent-timeout"
timeout_arg_log="$fixture_root/timeout-curl-args"
timeout_post_body="$fixture_root/timeout-post-body.json"
timeout_guard_log="$fixture_root/timeout-guard-log"
timeout_claim_count="$fixture_root/timeout-claim-count"
timeout_action_dir="$timeout_state_dir/actions/action-update-restart-hsb8-timeout"
mkdir -p "$timeout_action_dir"
cat >"$timeout_action_dir/internal.json" <<'JSON'
{
  "schema": "inspr.pharos.system-update-local.v1",
  "version": 1,
  "id": "action-update-restart-hsb8-timeout",
  "host": "hsb8",
  "ticket": "PHAROS-126",
  "status": "rebooting",
  "boot_id_before": "boot-current",
  "switched_at": "2026-07-13T05:04:32Z",
  "reboot_deadline_epoch": 1
}
JSON
sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$timeout_state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$timeout_agent"
chmod +x "$timeout_agent"
timeout_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$timeout_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$timeout_post_body" \
    FAKE_GUARD_LOG="$timeout_guard_log" \
    FAKE_STATE_DIR="$timeout_state_dir" \
    FAKE_CLAIM_PHASE=resume \
    FAKE_CLAIM_ID=action-update-restart-hsb8-timeout \
    FAKE_CLAIM_ONCE=1 \
    FAKE_CLAIM_COUNT_FILE="$timeout_claim_count" \
    FAKE_GUARD_RESUME_TIMEOUT=1 \
    "$timeout_agent" 2>&1
)
grep -Fq 'pharos_action_agent=timeout reason=reboot_not_observed' <<<"$timeout_output"
grep -Fq 'pharos_action_agent=reported phase=resume outcome=failed runner_ok=false' \
  <<<"$timeout_output"
jq -e '
  .phase == "resume"
  and .outcome == "failed"
  and .plan == null
  and .result.backup_validated == true
  and .result.switch_passed == true
  and .result.reboot_observed == false
  and .result.kernel_verified == false
  and .result.rollback_available == false
  and .result.failure_gate == "boot_change"
' "$timeout_post_body" >/dev/null
[ "$(grep -Fc 'update PHAROS-126 resume' "$timeout_guard_log")" -eq 1 ]

timeout_duplicate_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$timeout_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$timeout_post_body" \
    FAKE_GUARD_LOG="$timeout_guard_log" \
    FAKE_STATE_DIR="$timeout_state_dir" \
    FAKE_CLAIM_PHASE=resume \
    FAKE_CLAIM_ID=action-update-restart-hsb8-timeout \
    FAKE_CLAIM_ONCE=1 \
    FAKE_CLAIM_COUNT_FILE="$timeout_claim_count" \
    FAKE_GUARD_RESUME_TIMEOUT=1 \
    "$timeout_agent" 2>&1
)
grep -Fq 'pharos_action_agent=timeout reason=reboot_not_observed' \
  <<<"$timeout_duplicate_output"
grep -Fq 'pharos_action_agent=idle' <<<"$timeout_duplicate_output"
[ "$(<"$timeout_claim_count")" -eq 2 ]
[ "$(grep -Fc 'update PHAROS-126 resume' "$timeout_guard_log")" -eq 1 ]

printf 'boot-new\n' >"$boot_id_file"
mismatch_state_dir="$fixture_root/mismatch-state"
mismatch_agent="$fixture_root/pharos-host-action-agent-mismatch"
mismatch_arg_log="$fixture_root/mismatch-curl-args"
mismatch_guard_log="$fixture_root/mismatch-guard-log"
mismatch_action_dir="$mismatch_state_dir/actions/action-update-restart-hsb8-pending"
mkdir -p "$mismatch_action_dir"
cat >"$mismatch_action_dir/internal.json" <<'JSON'
{
  "schema": "inspr.pharos.system-update-local.v1",
  "version": 1,
  "id": "action-update-restart-hsb8-pending",
  "host": "hsb8",
  "ticket": "PHAROS-126",
  "status": "rebooting",
  "boot_id_before": "boot-current",
  "switched_at": "2026-07-13T05:04:32Z",
  "reboot_deadline_epoch": 4102444800
}
JSON
sed \
  -e 's|@HOST@|hsb8|g' \
  -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
  -e "s|@GUARDED_DEPLOY@|$fake_guard|g" \
  -e "s|@STATE_DIR@|$mismatch_state_dir|g" \
  -e "s|@BOOT_ID_FILE@|$boot_id_file|g" \
  -e 's|@REBOOT_TIMEOUT_SECONDS@|600|g' \
  "$agent_source" >"$mismatch_agent"
chmod +x "$mismatch_agent"
set +e
mismatch_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$mismatch_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$post_body" \
    FAKE_GUARD_LOG="$mismatch_guard_log" \
    FAKE_STATE_DIR="$mismatch_state_dir" \
    FAKE_CLAIM_PHASE=resume \
    FAKE_CLAIM_ID=action-update-restart-hsb8-other \
    "$mismatch_agent" 2>&1
)
mismatch_status=$?
set -e
[ "$mismatch_status" -ne 0 ]
grep -Fxq 'pharos_action_agent=blocked reason=invalid_reboot_resume_lease' \
  <<<"$mismatch_output"
[ ! -e "$mismatch_guard_log" ]
[ ! -e "$mismatch_state_dir/active-agent-request.json" ]
[ ! -e "$leak_log" ]

echo 'pharos_action_agent=passed'
