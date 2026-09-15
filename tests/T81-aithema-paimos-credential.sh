#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# T81 — NIX-501 protected Aithema-to-Paimos conversation credential boundary.
# Pure/static fixtures only: no NixOS evaluation, secret access, or live config.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash 4+ is required\n' "${0##*/}" >&2
  exit 2
fi

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'Aithema Paimos credential test failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/hosts/csb1/shared-flow.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"

nix-instantiate --parse "$helper" >/dev/null
nix-instantiate --parse "$host_config" >/dev/null
command -v jq >/dev/null
command -v python3 >/dev/null

work=$(mktemp -d "${TMPDIR:-/tmp}/nix501-t81.XXXXXX")
cleanup() {
  for fixture_file in \
    "$work/direct-only.json" \
    "$work/functions.sh" \
    "$work/paimos.json" \
    "$work/paimos-wrong-path.json" \
    "$work/selector.json" \
    "$work/conversation.key" \
    "$work/conversation-link.key"; do
    if [ -e "$fixture_file" ] || [ -L "$fixture_file" ]; then
      unlink "$fixture_file"
    fi
  done
  rmdir "$work"
}
trap cleanup EXIT HUP INT TERM

# Execute the exact production helper bodies. Their inputs are value-free
# globals so this fixture never reads the operator-owned config or key.
python3 - "$host_config" >"$work/functions.sh" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
begin = "      # NIX-501-PROTECTED-CONVERSATION-PREFLIGHT-BEGIN\n"
end = "      # NIX-501-PROTECTED-CONVERSATION-PREFLIGHT-END\n"
try:
    body = source.split(begin, 1)[1].split(end, 1)[0]
except IndexError as error:
    raise SystemExit("production preflight markers are missing") from error
for line in body.splitlines():
    print(line[6:] if line.startswith("      ") else line)
PY
# shellcheck source=/dev/null
source "$work/functions.sh"

nix-instantiate --eval --strict --json --expr "
  let f = import ${helper}; in f.aithema.paimosHarness
" >"$work/selector.json"
jq -e '. == {
  credentialFile:"/run/credentials/aithema-workspace.service/paimos-conversation-api-key",
  credentialName:"paimos-conversation-api-key",
  credentialSource:"/run/agenix/csb1-aithema-paimos-conversation-key",
  enable:false
}' "$work/selector.json" >/dev/null

stat_bin=$(command -v stat)
jq_bin=$(command -v jq)
expected_listen_host="10.253.253.1"
expected_listen_port=8787
expected_data_dir="/var/lib/aithema-workspace"
expected_public_origin="https://flow.inspr.at"
expected_public_base_path="/aithema"
paimos_credential_file="/run/credentials/aithema-workspace.service/paimos-conversation-api-key"

if ! "$stat_bin" -c '%u:%g:%a' "$work" >/dev/null 2>&1; then
  printf '%s\n' 'T81 requires GNU stat (the production preflight uses coreutils stat)' >&2
  exit 2
fi

expect_reject() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'fixture unexpectedly accepted: %s\n' "$label" >&2
    exit 1
  fi
}

: >"$work/conversation.key"
chmod 0400 "$work/conversation.key"
valid_metadata=$("$stat_bin" -c '%u:%g:%a' "$work/conversation.key")
fixture_uid=${valid_metadata%%:*}
fixture_tail=${valid_metadata#*:}

expect_reject absent \
  shared_flow_check_protected_file "$work/absent.key" fixture "$valid_metadata"
ln -s "$work/conversation.key" "$work/conversation-link.key"
expect_reject symlink \
  shared_flow_check_protected_file "$work/conversation-link.key" fixture "$valid_metadata"
chmod 0600 "$work/conversation.key"
expect_reject wrongmode \
  shared_flow_check_protected_file "$work/conversation.key" fixture "$valid_metadata"
chmod 0400 "$work/conversation.key"
expect_reject wrongowner \
  shared_flow_check_protected_file "$work/conversation.key" fixture "$((fixture_uid + 1)):$fixture_tail"
shared_flow_check_protected_file "$work/conversation.key" fixture "$valid_metadata"

jq -n --arg credential_file "$paimos_credential_file" '{
  mode:"production",
  listenHost:"10.253.253.1",
  listenPort:8787,
  dataDir:"/var/lib/aithema-workspace",
  publicOrigin:"https://flow.inspr.at",
  publicBasePath:"/aithema",
  identity:{
    kind:"jwt-jwks",
    browser_login:{client_id:"fixture-client"},
    memberships:["fixture-membership"]
  },
  defaultProvider:"direct-api",
  providers:{
    "direct-api":{kind:"openai-compatible"},
    "paimos-cli":{kind:"paimos-harness",credentialFile:$credential_file}
  }
}' >"$work/paimos.json"

runtime_config="$work/paimos.json"
paimos_harness_enabled=true
shared_flow_check_runtime_config

jq --arg wrong "/tmp/not-the-service-credential" \
  '.providers["paimos-cli"].credentialFile = $wrong' \
  "$work/paimos.json" >"$work/paimos-wrong-path.json"
runtime_config="$work/paimos-wrong-path.json"
expect_reject wrongcredentialpath shared_flow_check_runtime_config

jq 'del(.providers["paimos-cli"])' \
  "$work/paimos.json" >"$work/direct-only.json"
runtime_config="$work/direct-only.json"
expect_reject missingpaimosprovider shared_flow_check_runtime_config
paimos_harness_enabled=false
shared_flow_check_runtime_config

# The disabled module keeps its upstream single runtime-config credential. The
# enabled selector uses a forced list solely to preserve it and add the second.
grep -Fq 'serviceConfig.LoadCredential = lib.mkForce [' "$host_config"
grep -Fq '"runtime-config.json:${sharedFlow.aithema.configFile}"' "$host_config"
grep -Fq '"${sharedFlow.aithema.paimosHarness.credentialName}:${sharedFlow.aithema.paimosHarness.credentialSource}"' "$host_config"

printf '%s\n' 'aithema_paimos_credential=passed selector=false live_config_read=false'
