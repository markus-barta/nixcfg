#!/usr/bin/env bash
set -Eeuo pipefail

readonly OWNER='@OWNER@'
readonly REPO_PATH='@REPO_PATH@'
readonly CONTRACT_DIR='@CONTRACT_DIR@'
readonly STATE_DIR='/var/lib/pharos-provisioning-executor'
readonly SCOPE_ORGANIZATION='@SCOPE_ORGANIZATION@'
readonly SCOPE_PROJECT='@SCOPE_PROJECT@'
readonly SCOPE_REPOSITORY='@SCOPE_REPOSITORY@'
readonly SCOPE_ENVIRONMENT='@SCOPE_ENVIRONMENT@'
readonly VOLUME_PREFIX='janus_pharos_production'
readonly RUN_SCOPE="pharos/${OWNER}/production"
readonly LOCK_FILE='/run/lock/janus-pharos-production.lock'

mode=${1:-}
job_id=${2:-}
host=${3:-}
credential_ref=${4:-}
output_root=${5:-}
credential_may_exist=false

fail() {
  local reason=$1
  local created=${2:-false}
  printf 'janus_managed_beacon=failed reason=%s value_returned=false credential_created=%s\n' \
    "$reason" "$created" >&2
  exit 1
}

# Invoked only for an unexpected shell failure; explicit contract failures use
# fail() above and retain their reviewed reason.
# shellcheck disable=SC2329
unexpected_failure() {
  local failure_status=$?
  local failure_reason=janus_unavailable
  trap - ERR
  if [ "$credential_may_exist" = true ]; then
    failure_reason=uncertain_execution
  fi
  printf 'janus_managed_beacon=failed reason=%s value_returned=false credential_created=%s\n' \
    "$failure_reason" "$credential_may_exist" >&2
  exit "$failure_status"
}
trap unexpected_failure ERR

for dependency in awk docker flock git grep jq python3 sed stat tr; do
  command -v "$dependency" >/dev/null 2>&1 || fail janus_unavailable false
done

case "$mode" in
issue | prove-absent | retire) ;;
*) fail result_contract_invalid false ;;
esac
[[ "$job_id" =~ ^[a-z0-9][a-z0-9._-]{0,159}$ ]] || fail result_contract_invalid false
[ "${#job_id}" -le 96 ] || fail result_contract_invalid false
[[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail result_contract_invalid false
[[ "$credential_ref" =~ ^sec_[0-9a-f]{20}$ ]] || fail result_contract_invalid false
if [ "$mode" = issue ]; then
  [[ "$output_root" =~ ^/run/pharos-provisioning-executor/[A-Za-z0-9._/-]+$ ]] ||
    fail result_contract_invalid false
else
  [ -z "$output_root" ] || fail result_contract_invalid false
fi

for value in "$OWNER" "$SCOPE_ORGANIZATION" "$SCOPE_PROJECT" "$SCOPE_REPOSITORY" "$SCOPE_ENVIRONMENT"; do
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || fail result_contract_invalid false
done
[[ "$REPO_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail checkout_not_ready false
[[ "$CONTRACT_DIR" == "$REPO_PATH"/* ]] || fail checkout_not_ready false
[ -f "$CONTRACT_DIR/metadata.toml" ] || fail checkout_not_ready false
[ -f "$CONTRACT_DIR/runtime-lib.sh" ] || fail checkout_not_ready false
[ -f "$REPO_PATH/hosts/csb1/docker/docker-compose.yml" ] || fail checkout_not_ready false

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$REPO_PATH"
[[ "$(git -C "$REPO_PATH" branch --show-current)" = main ]] || fail checkout_not_ready false
[[ -z "$(git -C "$REPO_PATH" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail checkout_not_ready false
[[ "$(git -C "$REPO_PATH" rev-parse HEAD)" = "$(git -C "$REPO_PATH" rev-parse origin/main)" ]] ||
  fail checkout_not_ready false

secret_name="PHAROS_BEACON_$(printf '%s' "$host" | tr '[:lower:]-' '[:upper:]_')_TOKEN"
profile_id="profile.${secret_name}"
consumer_ref="consumer.pharos_beacon_${host}"
operation_id="pharos-managed-${job_id}"
description="Managed Pharos beacon for ${host}"
validation_probe='pharos-managed-bootstrap-ready'

# Use distinct subprocess names: Bash rejects command-prefix assignments that
# reuse the readonly scope variable names declared above.
if ! derived_refs=$(
  PHAROS_SCOPE_ORGANIZATION="$SCOPE_ORGANIZATION" \
    PHAROS_SCOPE_PROJECT="$SCOPE_PROJECT" \
    PHAROS_SCOPE_REPOSITORY="$SCOPE_REPOSITORY" \
    PHAROS_SCOPE_ENVIRONMENT="$SCOPE_ENVIRONMENT" \
    PHAROS_SECRET_NAME="$secret_name" \
    python3 - <<'PY'
import hashlib
import os
import struct

def field(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return struct.pack(">Q", len(encoded)) + encoded

canonical = b"".join(field(value) for value in (
    "janus-scope-v1",
    os.environ["PHAROS_SCOPE_ORGANIZATION"],
    os.environ["PHAROS_SCOPE_PROJECT"],
    os.environ["PHAROS_SCOPE_REPOSITORY"],
    os.environ["PHAROS_SCOPE_ENVIRONMENT"],
)) + b"\0\0"
scope_ref = "scp_" + hashlib.sha256(canonical).digest()[:20].hex()
digest = hashlib.sha256(
    b"janus-secret-ref-v2\0" + scope_ref.encode("ascii") + b"\0" +
    os.environ["PHAROS_SECRET_NAME"].encode("ascii")
).digest()
print(scope_ref, "sec_" + digest[:10].hex())
PY
); then
  fail janus_unavailable false
fi
read -r expected_scope_ref expected_ref extra_ref <<<"$derived_refs"
[[ "$expected_scope_ref" =~ ^scp_[0-9a-f]{40}$ ]] ||
  fail result_contract_invalid false
[[ "$expected_ref" =~ ^sec_[0-9a-f]{20}$ ]] ||
  fail result_contract_invalid false
[ -z "${extra_ref:-}" ] || fail result_contract_invalid false
[ "$expected_ref" = "$credential_ref" ] || fail result_contract_invalid false

image=$(
  awk '
    /^[[:space:]]+janus-engine-staged:/ { in_service = 1; next }
    in_service && /^    image:/ { print $2; exit }
    in_service && /^  [A-Za-z0-9_-]+:/ { exit }
  ' "$REPO_PATH/hosts/csb1/docker/docker-compose.yml"
)
[ -n "$image" ] || fail janus_unavailable false

job_dir="$STATE_DIR/janus/$job_id"
if [ "$mode" = prove-absent ]; then
  docker image inspect "$image" >/dev/null 2>&1 || fail janus_unavailable false
  [ -d /run/lock ] && [ ! -L /run/lock ] || fail janus_unavailable false
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail janus_unavailable false

  if [ -e "$job_dir" ] || [ -L "$job_dir" ]; then
    [ -d "$job_dir" ] && [ ! -L "$job_dir" ] ||
      fail uncertain_execution false
    [ "$(stat -c '%u %a' "$job_dir" 2>/dev/null)" = "0 700" ] ||
      fail uncertain_execution false
    jq -e \
      --arg job "$job_id" \
      --arg host "$host" \
      --arg credential_ref "$credential_ref" '
      .schema == "inspr.pharos.managed-janus-contract.v1"
      and .version == 1
      and .job == $job
      and .host == $host
      and .credential_ref == $credential_ref
      and (keys | sort == ["credential_ref","host","job","schema","version"])
    ' "$job_dir/contract.json" >/dev/null 2>&1 ||
      fail uncertain_execution false
  fi

  volume_present() {
    local volume=$1
    local matches
    if ! matches=$(docker volume ls --quiet --filter "name=^${volume}$" 2>/dev/null); then
      return 2
    fi
    if [ -z "$matches" ]; then
      return 1
    fi
    [ "$matches" = "$volume" ] || return 2
    docker volume inspect "$volume" >/dev/null 2>&1 || return 2
  }

  volume_path_absent() {
    local volume=$1
    local path=$2
    local presence
    if volume_present "$volume"; then
      presence=0
    else
      presence=$?
    fi
    case "$presence" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
    esac
    docker run --rm --network none --read-only \
      -v "${volume}:/proof:ro" \
      --entrypoint sh "$image" -c '
set -eu
path=$1
test ! -e "/proof/${path}"
test ! -L "/proof/${path}"
' sh "$path" >/dev/null 2>&1
  }

  volume_metadata_absent() {
    local volume=$1
    local name=$2
    local presence
    if volume_present "$volume"; then
      presence=0
    else
      presence=$?
    fi
    case "$presence" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
    esac
    docker run --rm --network none --read-only \
      -v "${volume}:/proof:ro" \
      --entrypoint sh "$image" -c '
set -eu
name=$1
path=/proof/metadata.toml
test -f "$path"
test ! -L "$path"
! grep -Eq "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"${name}\"[[:space:]]*$" "$path"
' sh "$name" >/dev/null 2>&1
  }

  volume_path_absent \
    "${VOLUME_PREFIX}_lifecycle" \
    "provisioning-entries/${operation_id}.json" ||
    fail uncertain_execution false
  volume_path_absent \
    "${VOLUME_PREFIX}_secrets" \
    "pharos/${host}/${secret_name}.age" ||
    fail uncertain_execution false
  volume_path_absent \
    "${VOLUME_PREFIX}_out" \
    "pharos/beacons/${host}.env" ||
    fail uncertain_execution false
  volume_path_absent \
    "${VOLUME_PREFIX}_out" \
    "pharos/beacon-token-hashes/${host}.json" ||
    fail uncertain_execution false
  volume_metadata_absent \
    "${VOLUME_PREFIX}_metadata" \
    "$secret_name" ||
    fail uncertain_execution false
  printf 'janus_managed_beacon=absent value_returned=false credential_created=false\n'
  exit 0
fi

mkdir -p "$STATE_DIR/janus" /run/lock
chmod 0700 "$STATE_DIR" "$STATE_DIR/janus"
exec 9>"$LOCK_FILE"
flock -n 9 || fail janus_unavailable false

# shellcheck disable=SC1091
source "$CONTRACT_DIR/runtime-lib.sh"
docker image inspect "$image" >/dev/null 2>&1 || fail janus_unavailable false
janus_pharos_prepare_runtime "$image" "$CONTRACT_DIR" "$VOLUME_PREFIX" \
  >/dev/null 2>&1 || fail janus_unavailable false
janus_pharos_prepare_age_identity \
  "$image" \
  "$JANUS_PHAROS_AGE_VOLUME" \
  "$JANUS_PHAROS_CONTAINER_UID" \
  "$JANUS_PHAROS_CONTAINER_GID" >/dev/null 2>&1 || fail janus_unavailable false

ensure_contract() {
  local temporary reviewed_at scope_ref
  if [ -d "$job_dir" ] && [ ! -L "$job_dir" ]; then
    [ "$(stat -c '%u %a' "$job_dir" 2>/dev/null)" = "0 700" ] ||
      fail result_contract_invalid false
    jq -e \
      --arg job "$job_id" \
      --arg host "$host" \
      --arg credential_ref "$credential_ref" '
      .schema == "inspr.pharos.managed-janus-contract.v1"
      and .version == 1
      and .job == $job
      and .host == $host
      and .credential_ref == $credential_ref
      and (keys | sort == ["credential_ref","host","job","schema","version"])
    ' "$job_dir/contract.json" >/dev/null 2>&1 || fail result_contract_invalid false
    return
  fi
  [ ! -e "$job_dir" ] && [ ! -L "$job_dir" ] || fail result_contract_invalid false

  temporary=$(mktemp -d "$STATE_DIR/janus/.contract.XXXXXX")
  chmod 0700 "$temporary"
  reviewed_at=$(date +%s)
  scope_ref=$expected_scope_ref

  jq -n \
    --arg job "$job_id" \
    --arg host "$host" \
    --arg credential_ref "$credential_ref" \
    '{schema:"inspr.pharos.managed-janus-contract.v1",version:1,job:$job,host:$host,credential_ref:$credential_ref}' \
    >"$temporary/contract.json"
  printf '[project]\nname = "pharos"\nrevision = "1.0"\n\n[profiles."%s"]\n%s = { description = "%s", required = true }\n' \
    "$host" "$secret_name" "$description" >"$temporary/secretspec.toml"
  printf '[validation]\n%s = { program = "/usr/bin/true", args = [] }\n' \
    "$validation_probe" >"$temporary/hooks.toml"
  printf '%s\n' \
    '[[env_files]]' \
    "id = \"${profile_id}\"" \
    "secret_ref = \"${credential_ref}\"" \
    "executor = \"pharos-managed@${OWNER}\"" \
    "destination = \"pharos-beacon-${host}\"" \
    'env = "PHAROS_TOKEN"' \
    "output = \"/run/janus/env/pharos/beacons/${host}.env\"" \
    '' \
    '[env_files.hash_sidecar]' \
    'format = "pharos-beacon-token-generation-v2"' \
    "subject = \"${host}\"" \
    "output = \"/run/janus/env/pharos/beacon-token-hashes/${host}.json\"" \
    '' \
    '[env_files.consumer]' \
    "consumer_ref = \"${consumer_ref}\"" \
    'kind = "service"' \
    'owner = "pharos"' \
    "environment = \"${SCOPE_ENVIRONMENT}\"" \
    'reload = "none"' \
    "validation = [\"${validation_probe}\"]" \
    'supports_dual_value = false' \
    "blast_radius = \"single managed Pharos host ${host}\"" \
    >"$temporary/managed-env-files.toml"
  jq -n \
    --arg scope_ref "$scope_ref" \
    --arg operation_id "$operation_id" \
    --arg secret_ref "$credential_ref" \
    --arg label "$description" \
    --arg profile_id "$profile_id" \
    --arg consumer_ref "$consumer_ref" \
    --arg profile "$host" \
    --arg probe "$validation_probe" \
    --argjson reviewed_at "$reviewed_at" '
    {
      schema_version:1,
      operation_id:$operation_id,
      secret_ref:$secret_ref,
      expected_scope_ref:$scope_ref,
      expected_label:$label,
      expected_owner:"pharos",
      expected_classification:"high_value",
      profile_id:$profile_id,
      consumer_ref:$consumer_ref,
      rotation_strategy:"generated",
      validation_probes:[$probe],
      input_max_bytes:4096,
      preflight_max_age_seconds:900,
      secretspec_manifest:"/work/secretspec.toml",
      secretspec_profile:$profile,
      age_store_dir:"/var/lib/janus/secrets",
      metadata_file:"/var/lib/janus/metadata/metadata.toml",
      profile_manifest:"/work/managed-env-files.toml",
      hook_manifest:"/work/hooks.toml",
      state_dir:"/var/lib/janus/lifecycle/provisioning-entries",
      audit_path:"/var/lib/janus/lifecycle/provisioning-audit.jsonl",
      reviewed_by:"pharos-managed-provisioning",
      reviewed_at_unix_secs:$reviewed_at,
      activation_reason:"PHAROS-175 managed bootstrap",
      reload_strategy:"none",
      source:{mode:"generated",alphabet:"url_safe",length:48}
    }' >"$temporary/entry-plan.json"
  jq -n --arg host "$host" '
    {
      schema:"inspr.pharos.janus-retirements.v1",
      version:1,
      retirements:[{
        host:$host,
        disposition:"destroyed",
        successor:null,
        credential_retirement_required:true,
        server_deletion:false
      }]
    }' >"$temporary/retired-hosts.json"
  chmod 0600 "$temporary"/*
  mv "$temporary" "$job_dir"
}

ensure_contract

admin_container() {
  docker run --rm --network none \
    -e JANUS_PRODUCT_MODE=self_hosted \
    -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
    -e JANUS_AGE_MANIFEST_FILE=/work/secretspec.toml \
    -e "JANUS_AGE_PROFILE=${host}" \
    -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
    -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
    -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
    -e "JANUS_LIFECYCLE_ENTRY_EXECUTOR=pharos-managed@${OWNER}" \
    -e "JANUS_LIFECYCLE_EXECUTOR=pharos-managed@${OWNER}" \
    -e "JANUS_LIFECYCLE_SCOPE=${RUN_SCOPE}" \
    -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
    -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
    -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
    -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
    -e JANUS_LIFECYCLE_TOMBSTONE_DIR=/var/lib/janus/lifecycle/tombstones \
    -v "${job_dir}:/work:ro" \
    -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age:ro" \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
    -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${JANUS_PHAROS_LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle" \
    --entrypoint janusd-admin "$image" "$@"
}

entry_phase() {
  local journal_posture output
  if ! journal_posture=$(docker run --rm --network none \
    -v "${JANUS_PHAROS_LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle:ro" \
    --entrypoint sh "$image" -c '
set -eu
path="/var/lib/janus/lifecycle/provisioning-entries/${1}.json"
if [ -f "$path" ] && [ ! -L "$path" ]; then
  printf "present\\n"
elif [ ! -e "$path" ] && [ ! -L "$path" ]; then
  printf "absent\\n"
else
  exit 1
fi
' sh "$operation_id" 2>/dev/null); then
    printf 'invalid\n'
    return
  fi
  if [ "$journal_posture" = absent ]; then
    printf 'absent\n'
    return
  fi
  [ "$journal_posture" = present ] || {
    printf 'invalid\n'
    return
  }
  if ! output=$(admin_container lifecycle-entry status --plan /work/entry-plan.json 2>&1); then
    printf 'invalid\n'
    return
  fi
  printf '%s\n' "$output" | grep -F 'value_returned=false' >/dev/null || {
    printf 'invalid\n'
    return
  }
  printf '%s\n' "$output" | sed -n 's/.* phase=\([a-z_]*\) .*/\1/p' | head -n1
}

run_entry() {
  local operation=$1
  local expected=$2
  local output
  if ! output=$(admin_container lifecycle-entry "$operation" --plan /work/entry-plan.json 2>&1); then
    return 1
  fi
  printf '%s\n' "$output" | grep -F 'value_returned=false' >/dev/null || return 1
  printf '%s\n' "$output" | grep -F "phase=${expected}" >/dev/null
}

verify_absent() {
  docker run --rm --network none \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets:ro" \
    -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$image" -c '
set -eu
host=$1
name=$2
test ! -e "/var/lib/janus/secrets/pharos/${host}/${name}.age"
test ! -e "/run/janus/env/pharos/beacons/${host}.env"
test ! -e "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
' sh "$host" "$secret_name" >/dev/null 2>&1
}

if [ "$mode" = retire ]; then
  phase=$(entry_phase)
  if [ "$phase" = completed ]; then
    credential_may_exist=true
  fi
  case "$phase" in
  absent | rolled_back)
    verify_absent || fail uncertain_execution true
    printf 'janus_managed_beacon=retired value_returned=false credential_created=false\n'
    exit 0
    ;;
  preflighted | applying | stored | validated | activating | rolling_back | failed)
    run_entry rollback rolled_back || fail uncertain_execution true
    verify_absent || fail uncertain_execution true
    printf 'janus_managed_beacon=retired value_returned=false credential_created=false\n'
    exit 0
    ;;
  completed) ;;
  *) fail result_contract_invalid true ;;
  esac

  retirement_output=''
  if ! retirement_output=$(admin_container \
    pharos-beacon retire \
    --host "$host" \
    --disposition destroyed \
    --intent-file /work/retired-hosts.json \
    --metadata-file /var/lib/janus/metadata/metadata.toml \
    --profile-manifest /work/managed-env-files.toml \
    --state-dir /var/lib/janus/lifecycle/pharos-retirements \
    --retain-for-days 365 2>&1); then
    fail janus_rejected true
  fi
  printf '%s\n' "$retirement_output" | grep -F 'state=complete' >/dev/null ||
    fail result_contract_invalid true
  printf '%s\n' "$retirement_output" | grep -F 'value_returned=false' >/dev/null ||
    fail result_contract_invalid true
  printf '%s\n' "$retirement_output" | grep -F 'provider_deleted=false' >/dev/null ||
    fail result_contract_invalid true
  printf 'janus_managed_beacon=retired value_returned=false credential_created=false\n'
  exit 0
fi

phase=$(entry_phase)
case "$phase" in
absent)
  run_entry preflight preflighted || fail janus_rejected false
  phase=preflighted
  ;;
invalid) fail result_contract_invalid false ;;
applying | stored | activating | rolling_back | failed) fail uncertain_execution true ;;
rolled_back) fail janus_rejected false ;;
esac
if [ "$phase" = validated ] || [ "$phase" = completed ]; then
  credential_may_exist=true
fi
if [ "$phase" = preflighted ]; then
  run_entry apply validated || fail uncertain_execution true
  credential_may_exist=true
  phase=validated
fi
if [ "$phase" = validated ]; then
  run_entry activate completed || fail uncertain_execution true
  phase=completed
fi
[ "$phase" = completed ] || fail result_contract_invalid true

work_dir=$(mktemp -d /run/pharos-provisioning-executor/.janus-use.XXXXXX)
chmod 0700 "$work_dir"
cleanup() {
  find "$work_dir" -type f -exec shred -u {} + 2>/dev/null || true
  rmdir "$work_dir" 2>/dev/null || true
}
trap cleanup EXIT

request_file="$work_dir/request.jsonl"
warden_output="$work_dir/warden.out"
warden_error="$work_dir/warden.err"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"pharos-managed-provisioning","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"request_use\",\"arguments\":{\"secret_ref\":\"${credential_ref}\",\"profile_id\":\"${profile_id}\",\"purpose\":\"PHAROS-175 managed bootstrap for ${host}\"}}}" \
  >"$request_file"

if ! docker run -i --rm --network none \
  -e JANUS_PRODUCT_MODE=self_hosted \
  -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
  -e JANUS_PERMIT_DIR=/run/janus/permits \
  -e JANUS_WARDEN_PERMIT_DIR=/run/janus/permits \
  -e JANUS_WARDEN_BACKEND=age \
  -e "JANUS_WARDEN_DESTINATION=pharos-beacon-${host}" \
  -e "JANUS_WARDEN_EXECUTOR=pharos-managed@${OWNER}" \
  -e "JANUS_WARDEN_SCOPE=${RUN_SCOPE}" \
  -e "JANUS_WARDEN_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
  -e "JANUS_WARDEN_SCOPE_PROJECT=${SCOPE_PROJECT}" \
  -e "JANUS_WARDEN_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
  -e "JANUS_WARDEN_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
  -e JANUS_WARDEN_AGE_MANIFEST_FILE=/work/secretspec.toml \
  -e JANUS_WARDEN_AGE_METADATA_FILE=/var/lib/janus/metadata/metadata.toml \
  -e "JANUS_WARDEN_AGE_PROFILE=${host}" \
  -e JANUS_WARDEN_AGE_STORE_DIR=/var/lib/janus/secrets \
  -e JANUS_WARDEN_AGE_IDENTITY_FILE=/run/janus/age/identity \
  -e JANUS_WARDEN_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
  -v "${job_dir}:/work:ro" \
  -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
  -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age:ro" \
  -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${JANUS_PHAROS_PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint janus-warden "$image" \
  <"$request_file" >"$warden_output" 2>"$warden_error"; then
  fail janus_rejected true
fi
permit=$(jq -r 'select(.id==2) | .result.structuredContent.result.permit_id // empty' \
  "$warden_output" | head -n1)
[[ "$permit" =~ ^use_[A-Za-z0-9_-]+$ ]] || fail result_contract_invalid true

preflight_output="$work_dir/preflight.out"
preflight_error="$work_dir/preflight.err"
if ! docker run --rm --network none \
  -e JANUS_PRODUCT_MODE=self_hosted \
  -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
  -e JANUS_RUN_PROFILE_MANIFEST=/work/managed-env-files.toml \
  -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
  -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
  -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
  -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
  -v "${job_dir}:/work:ro" \
  -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
  --entrypoint janusd-use "$image" \
  env-file preflight --profile "$profile_id" \
  >"$preflight_output" 2>"$preflight_error"; then
  fail janus_rejected true
fi
grep -F 'value_returned=false' "$preflight_output" >/dev/null ||
  fail result_contract_invalid true

render_output="$work_dir/render.out"
render_error="$work_dir/render.err"
if ! docker run --rm --network none \
  -e JANUS_PRODUCT_MODE=self_hosted \
  -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
  -e JANUS_RUN_PROFILE_MANIFEST=/work/managed-env-files.toml \
  -e JANUS_RUN_PERMIT_DIR=/run/janus/permits \
  -e "JANUS_RUN_EXECUTOR=pharos-managed@${OWNER}" \
  -e "JANUS_RUN_SCOPE=${RUN_SCOPE}" \
  -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
  -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
  -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
  -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
  -e JANUS_AGE_MANIFEST_FILE=/work/secretspec.toml \
  -e JANUS_AGE_METADATA_FILE=/var/lib/janus/metadata/metadata.toml \
  -e "JANUS_AGE_PROFILE=${host}" \
  -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
  -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
  -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
  -v "${job_dir}:/work:ro" \
  -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
  -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age:ro" \
  -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${JANUS_PHAROS_PERMIT_VOLUME}:/run/janus/permits" \
  -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
  --entrypoint janusd-use "$image" \
  env-file --profile "$profile_id" --permit "$permit" \
  >"$render_output" 2>"$render_error"; then
  fail janus_rejected true
fi
grep -F 'value_returned=false' "$render_output" >/dev/null ||
  fail result_contract_invalid true
grep -F 'hash_format=pharos-beacon-token-generation-v2' "$render_output" >/dev/null ||
  fail result_contract_invalid true

install -d -m 0700 "$output_root/etc" "$output_root/etc/pharos"
docker run --rm --network none --user 0 \
  -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env:ro" \
  -v "${output_root}:/handoff" \
  --entrypoint sh "$image" -c '
set -eu
host=$1
source_file="/run/janus/env/pharos/beacons/${host}.env"
test -f "$source_file"
test ! -L "$source_file"
install -o 0 -g 0 -m 0600 "$source_file" /handoff/etc/pharos/pharos-beacon.env
' sh "$host" >/dev/null 2>&1 || fail janus_unavailable true

handoff_file="$output_root/etc/pharos/pharos-beacon.env"
[ -f "$handoff_file" ] && [ ! -L "$handoff_file" ] || fail result_contract_invalid true
[ "$(stat -c %a "$handoff_file")" = 600 ] || fail result_contract_invalid true
[ "$(wc -l <"$handoff_file" | tr -d ' ')" = 1 ] || fail result_contract_invalid true
file_size=$(wc -c <"$handoff_file" | tr -d ' ')
[[ "$file_size" =~ ^[0-9]+$ ]] && [ "$file_size" -ge 30 ] && [ "$file_size" -le 600 ] ||
  fail result_contract_invalid true
grep -Eq '^PHAROS_TOKEN=[A-Za-z0-9._~+/=-]{16,512}$' "$handoff_file" ||
  fail result_contract_invalid true

printf 'janus_managed_beacon=issued value_returned=false credential_created=true\n'
