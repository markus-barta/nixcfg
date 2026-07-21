#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos retirement failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

DEFAULT_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_DIR=$(cd -- "${JANUS_PHAROS_CONTRACT_DIR:-$DEFAULT_SCRIPT_DIR}" && pwd)
COMPOSE_DIR=$(cd -- "${DEFAULT_SCRIPT_DIR}/../.." && pwd)
REPO_ROOT=$(cd -- "${DEFAULT_SCRIPT_DIR}/../../../../.." && pwd)
RETIREMENTS_FILE=${JANUS_PHAROS_RETIREMENTS_FILE:-${SCRIPT_DIR}/retired-hosts.json}
IMAGE=${JANUS_ENGINE_IMAGE:-}
VOLUME_PREFIX=${JANUS_PHAROS_VOLUME_PREFIX:-janus_pharos_production}
RUN_SCOPE=${JANUS_PHAROS_SCOPE:-pharos/csb1/production}
SCOPE_ORGANIZATION=${JANUS_PHAROS_SCOPE_ORGANIZATION:-inspr}
SCOPE_PROJECT=${JANUS_PHAROS_SCOPE_PROJECT:-pharos}
SCOPE_REPOSITORY=${JANUS_PHAROS_SCOPE_REPOSITORY:-nixcfg}
SCOPE_ENVIRONMENT=${JANUS_PHAROS_SCOPE_ENVIRONMENT:-production}
RETENTION_DAYS=${JANUS_PHAROS_RETENTION_DAYS:-365}
FIXTURE=${JANUS_PHAROS_RETIREMENT_FIXTURE:-0}
mode=${1:-}
host=${2:-}

# shellcheck disable=SC1091
source "${DEFAULT_SCRIPT_DIR}/runtime-lib.sh"

fail() {
  printf 'janus_pharos_retirement=failed reason=%s value_returned=false provider_deleted=false\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail missing_dependency
}

valid_identifier() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]
}

case "$mode" in
apply) command=retire ;;
reconcile) command=reconcile ;;
*) fail invalid_mode ;;
esac

[[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail invalid_host
valid_identifier "$VOLUME_PREFIX" || fail invalid_volume_prefix
valid_identifier "$SCOPE_ORGANIZATION" || fail invalid_scope_organization
valid_identifier "$SCOPE_PROJECT" || fail invalid_scope_project
valid_identifier "$SCOPE_REPOSITORY" || fail invalid_scope_repository
valid_identifier "$SCOPE_ENVIRONMENT" || fail invalid_scope_environment
[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || fail invalid_retention

for dependency in awk docker flock git jq; do
  require_command "$dependency"
done

[[ -f "$SCRIPT_DIR/secretspec.toml" ]] || fail missing_contract
[[ -f "$SCRIPT_DIR/managed-env-files.toml" ]] || fail missing_contract
[[ -f "$SCRIPT_DIR/metadata.toml" ]] || fail missing_contract
[[ -f "$RETIREMENTS_FILE" ]] || fail missing_intent

jq -e '
  ((keys | sort) == ["retirements", "schema", "version"])
  and .schema == "inspr.pharos.janus-retirements.v1"
  and .version == 1
  and (.retirements | type == "array")
  and all(.retirements[];
    ((keys | sort) == [
      "credential_retirement_required",
      "disposition",
      "host",
      "server_deletion",
      "successor"
    ])
    and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.disposition == "destroyed" or .disposition == "unmanaged" or .disposition == "rebuilt")
    and (.successor == null or (.successor | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")))
    and .credential_retirement_required == true
    and .server_deletion == false
  )
' "$RETIREMENTS_FILE" >/dev/null || fail invalid_intent

entry_count=$(jq --arg host "$host" '[.retirements[] | select(.host == $host)] | length' "$RETIREMENTS_FILE")
[[ "$entry_count" = 1 ]] || fail host_not_uniquely_retired
disposition=$(jq -r --arg host "$host" '.retirements[] | select(.host == $host) | .disposition' "$RETIREMENTS_FILE")
successor=$(jq -r --arg host "$host" '.retirements[] | select(.host == $host) | .successor // empty' "$RETIREMENTS_FILE")

if [ "$FIXTURE" != 1 ]; then
  [[ "$SCRIPT_DIR" = "$DEFAULT_SCRIPT_DIR" ]] || fail unreviewed_contract_path
  [[ "$RETIREMENTS_FILE" = "$DEFAULT_SCRIPT_DIR/retired-hosts.json" ]] || fail unreviewed_intent_path
  [[ "$(git -C "$REPO_ROOT" branch --show-current)" = main ]] || fail checkout_not_main
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || fail checkout_not_clean
  local_revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
  reviewed_revision=$(git -C "$REPO_ROOT" rev-parse origin/main)
  [[ "$local_revision" = "$reviewed_revision" ]] || fail checkout_not_reviewed
else
  [[ "$SCRIPT_DIR" != "$DEFAULT_SCRIPT_DIR" ]] || fail fixture_uses_production_contract
  [[ "$RETIREMENTS_FILE" = "$SCRIPT_DIR/retired-hosts.json" ]] || fail fixture_intent_mismatch
  [[ "$VOLUME_PREFIX" != janus_pharos_production ]] || fail fixture_uses_production_volumes
  [[ "$RUN_SCOPE" = pharos/csb1/nonprod-retirement-smoke ]] || fail fixture_uses_production_scope
fi

if [ -z "$IMAGE" ]; then
  IMAGE=$(
    awk '
      /^[[:space:]]+janus-engine-staged:/ { in_service = 1; next }
      in_service && /^    image:/ { print $2; exit }
      in_service && /^  [A-Za-z0-9_-]+:/ { exit }
    ' "${COMPOSE_DIR}/docker-compose.yml"
  )
fi
[[ -n "$IMAGE" ]] || fail missing_engine_image

LOCK_ROOT=${JANUS_PHAROS_LOCK_ROOT:-"${XDG_STATE_HOME:-${HOME}/.local/state}/janus-pharos-retirement"}
mkdir -p "$LOCK_ROOT"
chmod 0700 "$LOCK_ROOT"
exec 9>"${LOCK_ROOT}/${VOLUME_PREFIX}.lock"
flock -n 9 || fail retirement_in_progress

docker pull "$IMAGE" >/dev/null
janus_pharos_prepare_runtime "$IMAGE" "$SCRIPT_DIR" "$VOLUME_PREFIX"

docker run --rm \
  -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'test -s /run/janus/age/identity && test -s /run/janus/age/recipient.pub' ||
  fail runtime_identity_missing

args=(
  pharos-beacon "$command"
  --host "$host"
  --disposition "$disposition"
  --intent-file /etc/janus/retired-hosts.json
  --metadata-file /var/lib/janus/metadata/metadata.toml
  --profile-manifest /etc/janus/managed-env-files.toml
  --state-dir /var/lib/janus/lifecycle/pharos-retirements
  --retain-for-days "$RETENTION_DAYS"
)
if [ -n "$successor" ]; then
  args+=(--successor "$successor")
fi

error_file=$(mktemp)
cleanup() {
  rm -f "$error_file"
}
trap cleanup EXIT

if ! command_output=$(
  docker run --rm \
    -e JANUS_PRODUCT_MODE=self_hosted \
    -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
    -e JANUS_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
    -e "JANUS_AGE_PROFILE=${host}" \
    -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
    -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
    -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
    -e JANUS_LIFECYCLE_EXECUTOR=janus-pharos-retirement@csb1 \
    -e "JANUS_LIFECYCLE_SCOPE=${RUN_SCOPE}" \
    -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
    -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
    -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
    -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
    -e JANUS_LIFECYCLE_TOMBSTONE_DIR=/var/lib/janus/lifecycle/tombstones \
    -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
    -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
    -v "${RETIREMENTS_FILE}:/etc/janus/retired-hosts.json:ro" \
    -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age:ro" \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
    -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${JANUS_PHAROS_LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle" \
    --entrypoint janusd-admin "$IMAGE" \
    "${args[@]}" 2>"$error_file"
); then
  sed -n '1,20p' "$error_file" >&2
  fail engine_rejected_retirement
fi

if ! grep -Eq \
  "^janusd-admin pharos-beacon ${command} host=${host} state=(complete|needs_finalize|drift|action_required) reason_code=[a-z0-9_]+ value_returned=false provider_deleted=false$" \
  <<<"$command_output"; then
  fail invalid_engine_result
fi
if [ "$mode" = apply ] && ! grep -Fq ' state=complete ' <<<"$command_output"; then
  fail retirement_not_complete
fi

# The admin runtime temporarily makes the shared output private for mutation.
# Restore the read-only group boundary Pharos uses after the atomic generation
# pointer has revoked the retired host.
docker run --rm --user 0 \
  -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
root=/run/janus/env/pharos/beacon-token-hashes
chmod 0750 /run/janus/env/pharos "$root"
chmod 0640 "$root/current" "$root"/generation-*.json
for entry in "$root"/*.json; do
  [ -e "$entry" ] || continue
  chmod 0640 "$entry"
done
'

printf '%s\n' "$command_output"
