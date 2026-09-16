#!/usr/bin/env bash
# T83 — NIX-501 protected Paimos provider handoff and public credential wiring.
#
# Pure local fixtures only. The jq program is the value-free operator patch to
# apply to the decrypted workspace JSON in an attended agenix edit; this test
# never opens, decrypts, or writes an encrypted secret.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash 4+ is required\n' "${0##*/}" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
shared_flow="$repo_root/hosts/csb1/shared-flow.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"

for file in "$shared_flow" "$host_config"; do
  [ -f "$file" ]
  nix-instantiate --parse "$file" >/dev/null
done
command -v jq >/dev/null
command -v nix >/dev/null

work=$(mktemp -d "${TMPDIR:-/tmp}/nix501-t83.XXXXXX")
cleanup() {
  for fixture_file in \
    "$work/input.json" \
    "$work/output.json" \
    "$work/project-input.json" \
    "$work/project-output.json" \
    "$work/provider-patch.jq"; do
    if [ -e "$fixture_file" ] || [ -L "$fixture_file" ]; then
      unlink "$fixture_file"
    fi
  done
  rmdir "$work"
}
trap cleanup EXIT HUP INT TERM

# This is intentionally a public, value-free patch. It keeps all existing
# providers and policy fields, preserves OpenRouter as the default, and only
# widens a project override when that override already exists.
cp "$repo_root/scripts/nix501-paimos-provider-patch.jq" "$work/provider-patch.jq"
jq -n '{
  mode: "production",
  defaultProvider: "openrouter",
  policy: {
    allowedProviders: ["openrouter"],
    execution: "cloud",
    dataClass: "unclassified",
    allowedDataClasses: ["unclassified"],
    projects: {}
  },
  providers: {
    openrouter: {kind: "openai-compatible", preservedMarker: "keep-existing"}
  }
}' >"$work/input.json"
jq -f "$work/provider-patch.jq" "$work/input.json" >"$work/output.json"

jq -e '
  .defaultProvider == "openrouter"
  and .providers.openrouter.preservedMarker == "keep-existing"
  and .policy.allowedProviders == ["openrouter", "paimos-codex-worker-1"]
  and .providers["paimos-codex-worker-1"] == {
    kind: "paimos-harness",
    origin: "https://pm.barta.cm",
    credentialFile: "/run/credentials/aithema-workspace.service/paimos-conversation-api-key",
    projectID: "6",
    bindingID: "6cd8cafe-0166-4b06-b1b6-487426042d39",
    bindingRevision: 1,
    trustedIssuer: "https://auth.inspr.at",
    modelId: "gpt-5.6-sol",
    allowedModels: ["gpt-5.6-sol"],
    executionLocation: "cloud",
    allowedDataClasses: ["unclassified"]
  }
  and ((.policy.projects // {}) | has("project:52e00c70-2165-409d-80af-f9b8ed40ae40") | not)
' "$work/output.json" >/dev/null

# A pre-existing project override is widened in place; the patch never creates
# a new override or drops unrelated project fields.
jq '.policy.projects = {
  "project:52e00c70-2165-409d-80af-f9b8ed40ae40": {
    allowedProviders: ["openrouter"],
    preservedProjectMarker: "keep-existing"
  }
}' "$work/input.json" >"$work/project-input.json"
jq -f "$work/provider-patch.jq" "$work/project-input.json" >"$work/project-output.json"
jq -e '
  .policy.projects["project:52e00c70-2165-409d-80af-f9b8ed40ae40"].preservedProjectMarker
    == "keep-existing"
  and .policy.projects["project:52e00c70-2165-409d-80af-f9b8ed40ae40"].allowedProviders
    == ["openrouter", "paimos-codex-worker-1"]
' "$work/project-output.json" >/dev/null

# An override without its own provider list inherits the organization list.
# Adding Codex must not accidentally narrow that inherited list to Codex only.
jq 'del(.policy.projects["project:52e00c70-2165-409d-80af-f9b8ed40ae40"].allowedProviders)' \
  "$work/project-input.json" >"$work/input.json"
jq -f "$work/provider-patch.jq" "$work/input.json" >"$work/output.json"
jq -e '.policy.projects["project:52e00c70-2165-409d-80af-f9b8ed40ae40"].allowedProviders
  == ["openrouter", "paimos-codex-worker-1"]' "$work/output.json" >/dev/null

# Exercise the real attended-editor helper on synthetic data, including
# idempotence and refusal without changing the file on a conflicting binding.
editor="$repo_root/scripts/nix501-paimos-provider-editor.sh"
cp "$work/input.json" "$work/project-output.json"
test -z "$(bash "$editor" "$work/project-output.json")"
cmp "$work/output.json" "$work/project-output.json"
test -z "$(bash "$editor" "$work/project-output.json")"
cmp "$work/output.json" "$work/project-output.json"
jq '.providers["paimos-codex-worker-1"].bindingID = "different-binding"' \
  "$work/output.json" >"$work/input.json"
cp "$work/input.json" "$work/project-output.json"
if bash "$editor" "$work/project-output.json" >/dev/null 2>&1; then
  printf '%s\n' 'editor accepted conflicting binding' >&2
  exit 1
fi
cmp "$work/input.json" "$work/project-output.json"

selector_json=$(nix eval --impure --json --expr "(import $shared_flow).aithema.paimosHarness")
jq -e '
  .enable == true
  and .credentialSource == "/run/aithema-paimos-conversation-key"
  and .credentialName == "paimos-conversation-api-key"
  and .credentialFile == "/run/credentials/aithema-workspace.service/paimos-conversation-api-key"
' <<<"$selector_json" >/dev/null

recipients=$(nix eval --impure --json --expr \
  "(import $repo_root/secrets/secrets.nix).\"csb1-aithema-paimos-conversation-key.age\".publicKeys")
jq -e 'length == 3 and all(.[]; startswith("ssh-ed25519 "))' \
  <<<"$recipients" >/dev/null

grep -Fq 'age.secrets.csb1-aithema-paimos-conversation-key =' "$host_config"
grep -Fq 'lib.mkIf (sharedFlow.active && sharedFlow.aithema.paimosHarness.enable)' "$host_config"
grep -Fq 'file = ../../secrets/csb1-aithema-paimos-conversation-key.age;' "$host_config"
grep -Fq 'path = sharedFlow.aithema.paimosHarness.credentialSource;' "$host_config"
grep -Fq 'owner = "root";' "$host_config"
grep -Fq 'group = "root";' "$host_config"
grep -Fq 'mode = "0400";' "$host_config"
grep -Fq 'symlink = false;' "$host_config"
grep -Fq 'serviceConfig.LoadCredential = lib.mkForce [' "$host_config"
# Match literal Nix interpolation, not shell parameter expansion.
# shellcheck disable=SC2016
grep -Fq '"runtime-config.json:${sharedFlow.aithema.configFile}"' "$host_config"
# shellcheck disable=SC2016
grep -Fq '"${sharedFlow.aithema.paimosHarness.credentialName}:${sharedFlow.aithema.paimosHarness.credentialSource}"' "$host_config"

printf '%s\n' 'nix501_paimos_provider_handoff=passed protected_patch=fixture_only credential_plaintext_read=false'
