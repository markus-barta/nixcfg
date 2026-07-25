#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JANUS_TEST_FLAKE_REF="git+file://${repo}"
module="${repo}/modules/janus-host-secrets/default.nix"
host="${repo}/hosts/csb1/configuration.nix"

nix-instantiate --parse "${module}" >/dev/null
nix eval --impure --raw --file "${repo}/tests/janus-host-module-eval.nix" |
  grep -Fqx 'janus_host_module_eval=ok'

grep -Fq 'janus-host-executor restore' "${module}"
grep -Fq 'StateDirectoryMode = "0700"' "${module}"
grep -Fq 'RuntimeDirectoryMode = "0700"' "${module}"
grep -Fq 'requiredBy = cfg.beforeUnits' "${module}"
grep -Fq 'before = cfg.beforeUnits' "${module}"
grep -Fq 'ReadOnlyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]' "${module}"
grep -Fq 'CapabilityBoundingSet = ""' "${module}"
grep -Fq 'janus-managed-host-agent' "${module}"
grep -Fq 'managed-host-agent-config.v1' "${module}"
grep -Fq '"AF_INET"' "${module}"
grep -Fq 'compose_file = profile.composeFile' "${module}"
grep -Fq 'owner_uid = cfg.ownerUid' "${module}"
grep -Fq 'runtime paths are derived, not configurable' "${module}"
grep -Fq '../../modules/janus-host-secrets' "${host}"
grep -Fq 'inspr.janusHostSecrets = {' "${host}"
grep -Fq 'ownerUid = 65534' "${host}"
test "$(
  nix eval --json \
    "${JANUS_TEST_FLAKE_REF}#nixosConfigurations.csb1.config.inspr.janusHostSecrets.enable"
)" = "true"

if grep -Eq '(secret_value|private_key|ciphertext)[[:space:]]*=' "${host}"; then
  printf 'janus host declaration contains a forbidden value-bearing field\n' >&2
  exit 1
fi

printf 'janus_host_envelope_module=ok enabled=true boot_gate=canary value_returned=false\n'
