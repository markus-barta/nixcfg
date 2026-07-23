#!/usr/bin/env bash
set -euo pipefail

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'pharos provisioning executor test failed at line %s (exit %s)\n' \
    "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/pharos-provisioning-executor/default.nix"
executor_source="$repo_root/modules/pharos-provisioning-executor/executor.sh"
janus_source="$repo_root/modules/pharos-provisioning-executor/janus-credential.sh"
host_config="$repo_root/hosts/csb1/configuration.nix"
compose="$repo_root/hosts/csb1/docker/docker-compose.yml"

bash -n "$executor_source"
bash -n "$janus_source"
nix-instantiate --parse "$module" >/dev/null
grep -Fq 'runtimeDir = "/run/pharos-provisioning-executor";' "$module"
grep -Fq '../../modules/pharos-provisioning-executor' "$host_config"
grep -Fq 'enable = false;' "$host_config"
grep -Fq 'PHAROS_PROVISIONING_EXECUTOR_READY=0' "$compose"
grep -Fq 'PHAROS_PROVISIONING_OWNER_HOST=csb1' "$compose"
grep -Fq 'unset PHAROS_TOKEN' "$executor_source"
grep -Fq -- '--copy-host-keys' "$executor_source"
# shellcheck disable=SC2016
grep -Fq -- '--extra-files "$extra_files"' "$executor_source"
grep -Fq -- '--ssh-option StrictHostKeyChecking=yes' "$executor_source"
grep -Fq 'host_key_fingerprint' "$executor_source"
# shellcheck disable=SC2016
grep -Fq 'and .ssh_key_ref == $ssh_key_ref' "$executor_source"
grep -Fq 'flock -n 9' "$janus_source"
grep -Fq 'janus-secret-ref-v2\0' "$janus_source"
grep -Fq 'value_returned=false' "$janus_source"

if grep -Eq 'curl .*PHAROS_TOKEN|Authorization: Bearer.*--header|PHAROS_TOKEN=.*curl' \
  "$executor_source"; then
  printf 'provisioning executor can expose the owner token in process arguments\n' >&2
  exit 1
fi
if grep -Eq -- '--(secret-value|token-value|private-key)([=[:space:]]|$)' \
  "$executor_source" "$janus_source"; then
  printf 'managed provisioning contains a forbidden secret-value argument\n' >&2
  exit 1
fi

fixture_root=$(mktemp -d)
cleanup() {
  rm -r "$fixture_root"
}
trap cleanup EXIT

fake_bin="$fixture_root/bin"
fake_repo="$fixture_root/repo"
fake_state="$fixture_root/state"
fake_runtime="$fixture_root/run"
fake_template="$fixture_root/template"
fake_janus="$fixture_root/janus-helper"
agent="$fixture_root/executor"
mkdir -p "$fake_bin" "$fake_repo" "$fake_state" "$fake_runtime" "$fake_template"

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
case "$*" in
*' fetch '*) exit 0 ;;
*' branch --show-current') printf 'main\n' ;;
*' status --porcelain=v1 --untracked-files=all') ;;
*' rev-parse HEAD' | *' rev-parse origin/main') printf 'reviewed-revision\n' ;;
*) exit 1 ;;
esac
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
  --output) output=$2; shift 2 ;;
  --data-binary) body=${2#@}; shift 2 ;;
  --config) config=$2; shift 2 ;;
  http://*) url=$1; shift ;;
  *) shift ;;
  esac
done
[ -z "${PHAROS_TOKEN:-}" ] || printf 'token-env-leak\n' >"$FAKE_LEAK_LOG"
grep -Fq "$FAKE_TOKEN" "$config"
printf '%s\n' "$args" >>"$FAKE_CURL_ARGS"
case "$url" in
*/agent/provisioning/claim)
  lease_until=$(( $(date +%s) + 3600 ))
  jq -n --argjson lease_until "$lease_until" '{
    schema:"inspr.pharos.provisioning-agent-lease.v1",
    version:1,
    id:"managed-fixture-1",
    host:"fixturehost",
    ticket:"PHAROS-175",
    action:"retire",
    credential_ref:"sec_0123456789abcdefabcd",
    provider_id:"1234",
    lease_until:$lease_until,
    ssh_key_ref:"pharos-executor",
    role:"server",
    heartbeat_interval_secs:60
  }' >"$output"
  printf '200'
  ;;
*/agent/provisioning/*/result)
  cp "$body" "$FAKE_RESULT_BODY"
  : >"$output"
  printf '204'
  ;;
*) exit 1 ;;
esac
EOF

cat >"$fake_janus" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = retire ]
[ "$2" = managed-fixture-1 ]
[ "$3" = fixturehost ]
[ "$4" = sec_0123456789abcdefabcd ]
[ "$#" -eq 4 ]
[ -z "${PHAROS_TOKEN:-}" ] || printf 'token-env-leak\n' >"$FAKE_LEAK_LOG"
printf 'janus_managed_beacon=retired value_returned=false credential_created=false\n'
EOF

chmod +x "$fake_bin"/* "$fake_janus"
sed \
  -e 's|@OWNER@|csb1|g' \
  -e 's|@PHAROS_AGENT_URL@|http://100.64.0.4:8088|g' \
  -e 's|@PHAROS_PUBLIC_URL@|https://pharos.example.invalid|g' \
  -e "s|@STATE_DIR@|$fake_state|g" \
  -e "s|@RUNTIME_DIR@|$fake_runtime|g" \
  -e "s|@REPO_PATH@|$fake_repo|g" \
  -e 's|@IDENTITY_FILE@|/run/fixture-identity|g' \
  -e 's|@SSH_KEY_REF@|pharos-executor|g' \
  -e "s|@BOOTSTRAP_TEMPLATE@|$fake_template|g" \
  -e "s|@JANUS_HELPER@|$fake_janus|g" \
  "$executor_source" >"$agent"
chmod +x "$agent"

export FAKE_TOKEN='fixture-owner-token-1234567890'
export FAKE_CURL_ARGS="$fixture_root/curl-args.log"
export FAKE_LEAK_LOG="$fixture_root/leak.log"
export FAKE_RESULT_BODY="$fixture_root/result.json"

if ! PATH="$fake_bin:$PATH" PHAROS_TOKEN="$FAKE_TOKEN" "$agent" \
  >"$fixture_root/agent.out" 2>"$fixture_root/agent.err"; then
  if grep -Fq "$FAKE_TOKEN" "$fixture_root/agent.err"; then
    printf 'fixture agent failed; diagnostic suppressed because it contained fixture credentials\n' >&2
  else
    sed -n '1,20p' "$fixture_root/agent.err" >&2
  fi
  exit 1
fi
jq -e '{owner,host,action,outcome,credential_created} == {
  owner:"csb1",
  host:"fixturehost",
  action:"retire",
  outcome:"succeeded",
  credential_created:false
} and (.reason == null)' "$FAKE_RESULT_BODY" >/dev/null
[ ! -e "$fake_state/pending-result.json" ]
[ ! -e "$FAKE_LEAK_LOG" ]
if grep -Fq "$FAKE_TOKEN" "$FAKE_CURL_ARGS"; then
  printf 'provisioning executor exposed the owner token in curl arguments\n' >&2
  exit 1
fi

printf 'pharos_provisioning_executor=passed\n'
