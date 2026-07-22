#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=${JANUS_SMOKE_SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../runtime-image-policy.sh"

CONTAINER=${JANUS_ENGINE_CONTAINER:-janus-engine-staged}
PERMIT_VOLUME=${JANUS_SMOKE_PERMIT_VOLUME:-janus_engine_smoke_permits}
SECRET_REF=${JANUS_SMOKE_SECRET_REF:-sec_5b4032741aeaeb486a64}
PROFILE_ID=${JANUS_SMOKE_PROFILE_ID:-profile.JANUS_SMOKE}
FORBIDDEN_VALUE_PREFIX=${JANUS_SMOKE_FORBIDDEN_VALUE_PREFIX:-janus-nonprod-smoke-}
HEALTH_WAIT_SECONDS=${JANUS_MCP_HEALTH_WAIT_SECONDS:-30}
APPROVED_ARGS=("--help")

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command docker
require_command grep
require_command jq
require_command mktemp

case "$PERMIT_VOLUME" in
"" | *[!A-Za-z0-9_.-]*)
  printf 'janus run negative smoke failed: invalid permit volume: %s\n' "$PERMIT_VOLUME" >&2
  exit 1
  ;;
esac

status=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
if [ "$status" != "running" ]; then
  printf 'janus run negative smoke failed: %s is not running (status=%s)\n' "$CONTAINER" "${status:-missing}" >&2
  exit 1
fi

elapsed=0
while :; do
  health=$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$CONTAINER"
  )
  if [ "$health" = "healthy" ]; then
    break
  fi
  if [ "$elapsed" -ge "$HEALTH_WAIT_SECONDS" ]; then
    printf 'janus run negative smoke failed: %s is not healthy after %ss (health=%s)\n' \
      "$CONTAINER" "$HEALTH_WAIT_SECONDS" "$health" >&2
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

network_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER")
ports=$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$CONTAINER")
traefik=$(docker inspect --format '{{index .Config.Labels "traefik.enable"}}' "$CONTAINER")
container_user=$(docker inspect --format '{{.Config.User}}' "$CONTAINER")

case "$container_user" in
[0-9]*:[0-9]*) ;;
*)
  printf 'janus run negative smoke failed: expected numeric container uid:gid, got %s\n' "$container_user" >&2
  exit 1
  ;;
esac

if [ "$network_mode" != "none" ] || [ "$ports" != "{}" ] || [ "$traefik" != "false" ]; then
  printf 'janus run negative smoke failed: expected internal-only container, got network_mode=%s ports=%s traefik=%s\n' \
    "$network_mode" "$ports" "$traefik" >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

validate_permit_id() {
  case "$1" in
  use_[A-Za-z0-9_]*) ;;
  *)
    printf 'janus run negative smoke failed: malformed issued permit id: %s\n' "$1" >&2
    exit 1
    ;;
  esac
}

issue_permit() {
  purpose=$1
  out="${tmp_dir}/warden-${purpose}.out"
  err="${tmp_dir}/warden-${purpose}.err"
  req="${tmp_dir}/warden-${purpose}.jsonl"

  cat >"$req" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-run-negative-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${SECRET_REF}","profile_id":"${PROFILE_ID}","purpose":"negative janusd-use run ${purpose}"}}}
EOF

  docker exec -i "$CONTAINER" janus-warden <"$req" >"$out" 2>"$err"

  assert_no_value_material "$out" "$err"
  jq -e 'select(.id == 2)
    | .result.isError == false
      and .result.structuredContent.ok == true
      and .result.structuredContent.value_returned == false
      and .result.structuredContent.result.value_returned == false' \
    <"$out" >/dev/null

  permit=$(
    jq -r 'select(.id == 2) | .result.structuredContent.result.permit_id // empty' \
      <"$out" | head -n1
  )
  validate_permit_id "$permit"
  printf '%s\n' "$permit"
}

assert_no_value_material() {
  if grep -q "$FORBIDDEN_VALUE_PREFIX" "$@"; then
    printf 'janus run negative smoke failed: transcript exposed fixture value prefix\n' >&2
    exit 1
  fi
}

assert_negative_transcript() {
  out=$1
  err=$2
  assert_no_value_material "$out" "$err"
  if grep -q 'smoke:\[REDACTED\]' "$out" "$err"; then
    printf 'janus run negative smoke failed: denial transcript looked like a successful redacted run\n' >&2
    exit 1
  fi
  if grep -q 'reason_code=ok value_returned=false' "$err"; then
    printf 'janus run negative smoke failed: denial transcript reported ok\n' >&2
    exit 1
  fi
}

run_janusd() {
  name=$1
  permit=$2
  arg=$3
  out="${tmp_dir}/${name}.out"
  err="${tmp_dir}/${name}.err"

  set +e
  docker exec "$CONTAINER" janusd-use run \
    --profile "$PROFILE_ID" \
    --permit "$permit" \
    -- "$arg" >"$out" 2>"$err"
  rc=$?
  set -e

  printf '%s\n' "$rc" >"${tmp_dir}/${name}.rc"
}

expect_successful_consume() {
  name=$1
  permit=$2

  run_janusd "$name" "$permit" "${APPROVED_ARGS[0]}"
  rc=$(cat "${tmp_dir}/${name}.rc")
  if [ "$rc" != "0" ]; then
    printf 'janus run negative smoke failed: expected %s to consume permit successfully (rc=%s)\n' "$name" "$rc" >&2
    sed -n '1,80p' "${tmp_dir}/${name}.out" >&2
    sed -n '1,120p' "${tmp_dir}/${name}.err" >&2
    exit 1
  fi
  assert_no_value_material "${tmp_dir}/${name}.out" "${tmp_dir}/${name}.err"
  if [ -s "${tmp_dir}/${name}.out" ]; then
    printf 'janus run negative smoke failed: successful consume returned unexpected stdout\n' >&2
    sed -n '1,80p' "${tmp_dir}/${name}.out" >&2
    exit 1
  fi
  grep -q 'reason_code=ok value_returned=false' "${tmp_dir}/${name}.err"
}

expect_denial() {
  name=$1
  permit=$2
  expected=$3
  arg=${4:-${APPROVED_ARGS[0]}}

  run_janusd "$name" "$permit" "$arg"
  rc=$(cat "${tmp_dir}/${name}.rc")
  if [ "$rc" = "0" ]; then
    printf 'janus run negative smoke failed: expected %s to fail\n' "$name" >&2
    sed -n '1,80p' "${tmp_dir}/${name}.out" >&2
    sed -n '1,120p' "${tmp_dir}/${name}.err" >&2
    exit 1
  fi
  assert_negative_transcript "${tmp_dir}/${name}.out" "${tmp_dir}/${name}.err"
  if ! grep -q "$expected" "${tmp_dir}/${name}.err"; then
    printf 'janus run negative smoke failed: %s did not contain %s\n' "$name" "$expected" >&2
    sed -n '1,80p' "${tmp_dir}/${name}.out" >&2
    sed -n '1,120p' "${tmp_dir}/${name}.err" >&2
    exit 1
  fi
}

rewrite_permit() {
  permit=$1
  filter=$2
  src="${tmp_dir}/${permit}.json"
  dst="${tmp_dir}/${permit}.mutated.json"

  validate_permit_id "$permit"
  docker run --rm \
    -v "${PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint cat "$JANUS_VOLUME_HELPER_IMAGE" \
    "/run/janus/permits/${permit}.json" >"$src"
  jq "$filter" "$src" >"$dst"
  docker run -i --rm \
    --user "$container_user" \
    -v "${PERMIT_VOLUME}:/run/janus/permits" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'umask 077; cat >"$1"; chmod 0600 "$1"' sh \
    "/run/janus/permits/${permit}.json" <"$dst"
}

remove_permit() {
  permit=$1
  validate_permit_id "$permit"
  docker run --rm \
    --user "$container_user" \
    -v "${PERMIT_VOLUME}:/run/janus/permits" \
    --entrypoint rm "$JANUS_VOLUME_HELPER_IMAGE" \
    -f "/run/janus/permits/${permit}.json"
}

expect_denial malformed_permit not_a_permit 'invalid --permit token'
expect_denial unknown_permit use_unknownfixture 'denied_unknown_permit'

reuse_permit=$(issue_permit consumed_reuse)
expect_successful_consume consume_once "$reuse_permit"
expect_denial consumed_reuse "$reuse_permit" 'denied_unknown_permit'

wrong_executor_permit=$(issue_permit wrong_executor)
rewrite_permit "$wrong_executor_permit" '.executor = "janus-run@other-host"'
expect_denial wrong_executor "$wrong_executor_permit" 'denied_permit_binding_mismatch'

wrong_destination_permit=$(issue_permit wrong_destination)
rewrite_permit "$wrong_destination_permit" '.destination = "attacker.example"'
expect_denial wrong_destination "$wrong_destination_permit" 'denied_permit_binding_mismatch'

expired_permit=$(issue_permit expired_permit)
rewrite_permit "$expired_permit" '.expires_at_unix_secs = 1'
expect_denial expired_permit "$expired_permit" 'denied_permit_binding_mismatch'

unreviewed_args_permit=$(issue_permit unreviewed_args)
expect_denial unreviewed_args "$unreviewed_args_permit" 'reviewed profile' '--version'
remove_permit "$unreviewed_args_permit"

remaining_permits=$(
  docker run --rm \
    -v "${PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f \( -name "use_*.json" -o -name ".use_*.claim" \) | wc -l | tr -d " "'
)
if [ "$remaining_permits" != "0" ]; then
  printf 'janus run negative smoke failed: permit registry not empty after negative run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus staged run negative smoke passed container=%s health=%s network_mode=%s ports=%s traefik=%s denials=malformed:invalid_token,unknown:denied_unknown_permit,consumed_reuse:denied_unknown_permit,wrong_executor:denied_permit_binding_mismatch,wrong_destination:denied_permit_binding_mismatch,expired:denied_permit_binding_mismatch,unreviewed_args:reviewed_profile value_returned=false no_literal=true permits_remaining=0\n' \
  "$CONTAINER" "$health" "$network_mode" "$ports" "$traefik"
