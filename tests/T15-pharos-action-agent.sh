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
  cat >"$output" <<'JSON'
{"schema":"inspr.pharos.host-action-lease.v1","version":1,"id":"action-update-restart-hsb8-100-1","host":"hsb8","ticket":"PHAROS-126","phase":"review"}
JSON
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
printf '%s %s\n' "$1" "$2" >"$FAKE_GUARD_LOG"
request="$FAKE_STATE_DIR/active-agent-request.json"
action_id=$(jq -r '.id' "$request")
action_dir="$FAKE_STATE_DIR/actions/$action_id"
mkdir -p "$action_dir"
if [ "${FAKE_GUARD_IDEMPOTENT:-0}" = 1 ]; then
  printf 'phase=review invoked_at=fixture\n' >"$action_dir/last-invocation.tmp"
  mv "$action_dir/last-invocation.tmp" "$action_dir/last-invocation"
  printf 'pharos_system_update=idempotent phase=review value_returned=false\n'
  exit 0
fi
if [ "${FAKE_GUARD_TYPED_FAIL:-0}" = 1 ]; then
  printf 'phase=review invoked_at=fixture\n' >"$action_dir/last-invocation.tmp"
  mv "$action_dir/last-invocation.tmp" "$action_dir/last-invocation"
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
grep -Fxq 'update PHAROS-126' "$guard_log"
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

waiting_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$waiting_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$waiting_state_dir" \
    "$waiting_agent" 2>&1
)
grep -Fxq 'pharos_action_agent=deferred reason=waiting_for_reboot' <<<"$waiting_output"
[ ! -e "$waiting_arg_log" ]

printf 'boot-new\n' >"$boot_id_file"
post_boot_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$waiting_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$waiting_state_dir" \
    FAKE_CURL_UNREACHABLE=1 \
    "$waiting_agent" 2>&1
)
grep -Fxq 'pharos_action_agent=deferred reason=claim_unreachable' <<<"$post_boot_output"
[ -s "$waiting_arg_log" ]

printf 'boot-current\n' >"$boot_id_file"
jq '.reboot_deadline_epoch = 1' "$waiting_action_dir/internal.json" \
  >"$waiting_action_dir/internal.json.tmp"
mv "$waiting_action_dir/internal.json.tmp" "$waiting_action_dir/internal.json"
timeout_output=$(
  PATH="$fake_bin:$PATH" \
    PHAROS_TOKEN="$token" \
    FAKE_TOKEN="$token" \
    FAKE_ARG_LOG="$waiting_arg_log" \
    FAKE_LEAK_LOG="$leak_log" \
    FAKE_POST_BODY="$post_body" \
    FAKE_GUARD_LOG="$guard_log" \
    FAKE_STATE_DIR="$waiting_state_dir" \
    FAKE_CURL_UNREACHABLE=1 \
    "$waiting_agent" 2>&1
)
grep -Fq 'pharos_action_agent=timeout reason=reboot_not_observed' <<<"$timeout_output"
grep -Fq 'pharos_action_agent=deferred reason=claim_unreachable' <<<"$timeout_output"
[ ! -e "$leak_log" ]

echo 'pharos_action_agent=passed'
