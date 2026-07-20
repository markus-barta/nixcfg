#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/pharos-retirement-executor/default.nix"
executor_source="$repo_root/modules/pharos-retirement-executor/executor.sh"
host_config="$repo_root/hosts/csb1/configuration.nix"
compose="$repo_root/hosts/csb1/docker/docker-compose.yml"

bash -n "$executor_source"
grep -Fq '../../modules/pharos-retirement-executor' "$host_config"
grep -Fq 'inspr.pharosRetirementExecutor.enable = true;' "$host_config"
grep -Fq 'EnvironmentFile = cfg.tokenEnvironmentFile;' "$module"
grep -Fq 'restartIfChanged = false;' "$module"
grep -Fq 'PHAROS_HOST_REMOVAL_DISPATCH_ENABLED=1' "$compose"
grep -Fq 'PHAROS_RETIREMENT_OWNER_HOST=csb1' "$compose"
[ "$(grep -Fc 'ghcr.io/markus-barta/pharos/pharosd:0.1.49' "$compose")" -eq 2 ]
grep -Fq 'PHAROS_JANUS_PUBLIC_URL=https://vault.barta.cm' "$compose"
grep -Fq 'unset PHAROS_TOKEN' "$executor_source"
# shellcheck disable=SC2016
grep -Fq -- '--config "$auth_config"' "$executor_source"
# shellcheck disable=SC2016
grep -Fq '.host != $owner' "$executor_source"
grep -Fq 'provider_deleted=false' "$executor_source"

if grep -Eq 'curl .*PHAROS_TOKEN|Authorization: Bearer.*--header|PHAROS_TOKEN=.*curl' \
  "$executor_source"; then
  printf 'retirement executor can expose the beacon token in curl arguments\n' >&2
  exit 1
fi
if grep -Eq -- '--(provider-delete|delete-server|secret|token)([=[:space:]]|$)' \
  "$executor_source"; then
  printf 'retirement executor contains a forbidden destructive or secret argument\n' >&2
  exit 1
fi

fixture_root=$(mktemp -d)
cleanup() {
  rm -r "$fixture_root"
}
trap cleanup EXIT

fake_bin="$fixture_root/bin"
fake_repo="$fixture_root/repo"
fake_helper="$fake_repo/hosts/csb1/docker/janus/pharos-production/retire-host.sh"
mkdir -p "$fake_bin" "$(dirname "$fake_helper")"

cat >"$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1-}" = -u ] || exit 1
printf '0\n'
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

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GIT_LOG"
exit 0
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

[ -z "${PHAROS_TOKEN:-}" ] || printf 'token-env-leak\n' >"$FAKE_LEAK_LOG"
grep -Fq "$FAKE_TOKEN" "$config"
printf '%s\n' "$args" >>"$FAKE_CURL_ARG_LOG"

case "$url" in
*/agent/retirements/claim)
  if [ "${FAKE_CLAIM_MODE:-lease}" = idle ]; then
    : >"$output"
    printf '204'
    exit 0
  fi
  jq -n --arg host "$FAKE_CLAIM_HOST" '{
    schema:"inspr.pharos.retirement-agent-lease.v1",
    version:1,
    id:"retirement-fixture-1",
    host:$host,
    ticket:"PHAROS-127"
  }' >"$output"
  printf '200'
  ;;
*/agent/retirements/*/result)
  result_count=0
  if [ -r "$FAKE_RESULT_COUNT_FILE" ]; then
    result_count=$(<"$FAKE_RESULT_COUNT_FILE")
  fi
  result_count=$((result_count + 1))
  printf '%s\n' "$result_count" >"$FAKE_RESULT_COUNT_FILE"
  cp "$body" "$FAKE_POST_BODY"
  if [ "${FAKE_RESULT_MODE:-success}" = unreachable-once ] && \
    [ "$result_count" -eq 1 ]; then
    exit 28
  fi
  : >"$output"
  printf '204'
  ;;
*) exit 1 ;;
esac
EOF

cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "$1" = apply ]
[ "$2" = "$FAKE_CLAIM_HOST" ]
[ -z "${PHAROS_TOKEN:-}" ] || printf 'token-env-leak\n' >"$FAKE_LEAK_LOG"
printf '%s\n' "$*" >>"$FAKE_HELPER_LOG"
case "${FAKE_HELPER_MODE:-success}" in
success)
  printf 'janusd pharos-beacon retire host=%s state=complete reason_code=retired value_returned=false provider_deleted=false\n' "$2"
  ;;
checkout)
  printf 'janus_pharos_retirement=failed reason=checkout_not_clean value_returned=false provider_deleted=false\n' >&2
  exit 1
  ;;
*) exit 1 ;;
esac
EOF

chmod +x "$fake_bin"/* "$fake_helper"

make_agent() {
  local name=$1
  local state_dir="$fixture_root/state-$name"
  local agent="$fixture_root/executor-$name"
  mkdir -p "$state_dir"
  sed \
    -e 's|@OWNER@|csb1|g' \
    -e 's|@PHAROS_URL@|http://100.64.0.4:8088|g' \
    -e "s|@STATE_DIR@|$state_dir|g" \
    -e "s|@REPO_PATH@|$fake_repo|g" \
    -e "s|@RETIRE_HELPER@|$fake_helper|g" \
    "$executor_source" >"$agent"
  chmod +x "$agent"
  printf '%s\n' "$agent"
}

run_agent() {
  local agent=$1
  PATH="$fake_bin:$PATH" PHAROS_TOKEN="$FAKE_TOKEN" "$agent"
}

export FAKE_TOKEN='fixture-token-value-1234567890'
export FAKE_GIT_LOG="$fixture_root/git.log"
export FAKE_HELPER_LOG="$fixture_root/helper.log"
export FAKE_CURL_ARG_LOG="$fixture_root/curl-args.log"
export FAKE_LEAK_LOG="$fixture_root/leak.log"
export FAKE_POST_BODY="$fixture_root/post-body.json"
export FAKE_RESULT_COUNT_FILE="$fixture_root/result-count"
export FAKE_CLAIM_HOST=hsb8
export FAKE_CLAIM_MODE=lease
export FAKE_HELPER_MODE=success
export FAKE_RESULT_MODE=success

success_agent=$(make_agent success)
run_agent "$success_agent" >"$fixture_root/success.out" 2>"$fixture_root/success.err"
jq -e '{owner,host,outcome} == {
  owner:"csb1",
  host:"hsb8",
  outcome:"succeeded"
} and (.reason == null)' "$FAKE_POST_BODY" >/dev/null
[ "$(wc -l <"$FAKE_HELPER_LOG" | tr -d ' ')" -eq 1 ]
[ ! -e "$fixture_root/state-success/pending-result.json" ]
[ ! -e "$FAKE_LEAK_LOG" ]
if grep -Fq "$FAKE_TOKEN" "$FAKE_CURL_ARG_LOG"; then
  printf 'retirement executor exposed the token in curl arguments\n' >&2
  exit 1
fi

: >"$FAKE_HELPER_LOG"
: >"$FAKE_CURL_ARG_LOG"
rm -f "$FAKE_RESULT_COUNT_FILE" "$FAKE_POST_BODY"
export FAKE_RESULT_MODE=unreachable-once
retry_agent=$(make_agent retry)
run_agent "$retry_agent" >"$fixture_root/retry-1.out" 2>"$fixture_root/retry-1.err"
[ -f "$fixture_root/state-retry/pending-result.json" ]
[ "$(wc -l <"$FAKE_HELPER_LOG" | tr -d ' ')" -eq 1 ]
run_agent "$retry_agent" >"$fixture_root/retry-2.out" 2>"$fixture_root/retry-2.err"
[ ! -e "$fixture_root/state-retry/pending-result.json" ]
[ "$(wc -l <"$FAKE_HELPER_LOG" | tr -d ' ')" -eq 1 ]

: >"$FAKE_HELPER_LOG"
rm -f "$FAKE_RESULT_COUNT_FILE" "$FAKE_POST_BODY"
export FAKE_RESULT_MODE=success
export FAKE_HELPER_MODE=checkout
failure_agent=$(make_agent failure)
run_agent "$failure_agent" >"$fixture_root/failure.out" 2>"$fixture_root/failure.err"
jq -e '.outcome == "failed" and .reason == "checkout_not_ready"' \
  "$FAKE_POST_BODY" >/dev/null

: >"$FAKE_HELPER_LOG"
export FAKE_CLAIM_HOST=csb1
export FAKE_HELPER_MODE=success
self_agent=$(make_agent self)
if run_agent "$self_agent" >"$fixture_root/self.out" 2>"$fixture_root/self.err"; then
  printf 'retirement executor accepted itself as the target\n' >&2
  exit 1
fi
[ ! -s "$FAKE_HELPER_LOG" ]

printf 'pharos_retirement_executor=passed\n'
