#!/usr/bin/env bash
set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture_dir=$(mktemp -d)
fixture="$fixture_dir/pharos-host-preferences.json"
cp "$repo_root/modules/pharos-host-preferences.json" "$fixture"

jq -e '
  (.hosts | keys) == ["csb0", "csb1", "hsb0", "hsb1", "hsb8", "hsb9"]
' "$fixture" >/dev/null

compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
[[ "$(grep -Fc 'PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules' "$compose")" == 1 ]]
[[ "$(grep -Fc '/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro' "$compose")" == 1 ]]
[[ "$(grep -Fc 'PHAROS_HOST_PREFERENCES_PATH=/config/pharos-host-preferences.json' "$compose")" == 1 ]]
[[ "$(grep -Fc '/home/mba/Code/nixcfg/modules/pharos-host-preferences.json:/config/pharos-host-preferences.json:ro' "$compose")" == 1 ]]
[[ "$(grep -Fc 'PHAROS_NIXCFG_DISPATCH_ENABLED=1' "$compose")" == 1 ]]
[[ "$(grep -Fc 'PHAROS_NIXCFG_DISPATCH_TOKEN_FILE=/run/pharos/nixcfg-dispatch-token' "$compose")" == 1 ]]
[[ "$(grep -Fc '/run/agenix/csb1-pharos-nixcfg-dispatch-token:/run/pharos/nixcfg-dispatch-token:ro' "$compose")" == 1 ]]
if grep -Eq 'PHAROS_NIXCFG_DISPATCH_TOKEN=' "$compose"; then
  exit 1
fi
grep -Fq 'age.secrets.csb1-pharos-nixcfg-dispatch-token' "$host_config"
grep -Fq 'file = ../../secrets/csb1-pharos-nixcfg-dispatch-token.age;' "$host_config"
for host in csb0 csb1 hsb0 hsb1 hsb8 hsb9; do
  beacon_compose="$repo_root/hosts/$host/docker/compose-spec.nix"
  [[ "$(grep -Fc 'PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json' "$beacon_compose")" == 1 ]]
  [[ "$(grep -Fc '/run/pharos-preferences:/etc/pharos:ro' "$beacon_compose")" == 1 ]]
  if grep -Fq '/etc/pharos/host-preferences.json:/etc/pharos/host-preferences.json' \
    "$beacon_compose"; then
    echo "generation-pinning preferences file mount found for $host" >&2
    exit 1
  fi
done
grep -Fq 'environment.etc."pharos/host-preferences.json".source = ./pharos-host-preferences.json;' \
  "$repo_root/modules/common.nix"
grep -Fq 'system.activationScripts.pharosHostPreferences' "$repo_root/modules/common.nix"
grep -Fq \
  'install -m 0644 /etc/pharos/host-preferences.json /run/pharos-preferences/.host-preferences.json.tmp' \
  "$repo_root/modules/common.nix"
grep -Fq \
  'mv -f /run/pharos-preferences/.host-preferences.json.tmp /run/pharos-preferences/host-preferences.json' \
  "$repo_root/modules/common.nix"

workflow="$repo_root/.github/workflows/pharos-host-settings.yml"
outcome_writer="$repo_root/scripts/write-pharos-host-settings-outcome.sh"
grep -Fq 'scripts/write-pharos-host-settings-outcome.sh' "$workflow"
grep -Fq \
  'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2' \
  "$workflow"
# shellcheck disable=SC2016 # Literal GitHub Actions expressions.
grep -Fq 'name: pharos-host-settings-outcome-${{ github.run_id }}-${{ github.run_attempt }}' \
  "$workflow"

# NIX-402: changing the registry dirties the flake, and NIX-348 correctly
# rejects a dirty self.rev. The workflow must commit both proposed states before
# evaluating them, and pipefail must prevent jq from masking a failed nix eval.
# shellcheck disable=SC2016 # Literal workflow shell expression.
settings_commit_line=$(grep -nF 'git commit -m "pharos: stage $PHAROS_HOST host settings for validation"' \
  "$workflow" | cut -d: -f1)
manifest_eval_line=$(grep -nF '.#nixosConfigurations.hsb8.config.services.hostdash.manifest.generated' \
  "$workflow" | cut -d: -f1)
manifest_commit_line=$(grep -nF "git commit -m 'pharos: regenerate declared hsb8 manifest'" \
  "$workflow" | cut -d: -f1)
# shellcheck disable=SC2016 # Literal GitHub Actions expression.
target_eval_line=$(grep -nF '".#nixosConfigurations.${PHAROS_HOST}.config.system.build.toplevel.drvPath"' \
  "$workflow" | cut -d: -f1)
[[ -n "$settings_commit_line" && -n "$manifest_eval_line" &&
  -n "$manifest_commit_line" && -n "$target_eval_line" ]]
((settings_commit_line < manifest_eval_line))
((manifest_eval_line < manifest_commit_line))
((manifest_commit_line < target_eval_line))
[[ "$(grep -Fc 'set -euo pipefail' "$workflow")" -ge 3 ]]
grep -Fq 'git diff --cached --quiet --exit-code' "$workflow"
# shellcheck disable=SC2016 # Literal workflow shell expression.
grep -Fq 'chmod 0644 "$manifest"' "$workflow"
grep -Fq "git diff --exit-code -- \\" "$workflow"

already_declared_outcome="$fixture_dir/already-declared.json"
GITHUB_REPOSITORY=markus-barta/nixcfg \
  GITHUB_RUN_ID=12345 \
  GITHUB_RUN_ATTEMPT=1 \
  "$outcome_writer" csb0 test-request-1 already_declared '' \
  "$already_declared_outcome" >/dev/null
jq -e '
  . == {
    schema: "inspr.pharos.host-settings-outcome.v1",
    request_id: "test-request-1",
    host: "csb0",
    outcome: "already_declared",
    repository: "markus-barta/nixcfg",
    workflow_run_id: 12345,
    workflow_run_attempt: 1,
    pull_request_number: null
  }
' "$already_declared_outcome" >/dev/null

merged_outcome="$fixture_dir/merged.json"
GITHUB_REPOSITORY=markus-barta/nixcfg \
  GITHUB_RUN_ID=12346 \
  GITHUB_RUN_ATTEMPT=2 \
  "$outcome_writer" hsb8 test-request-2 merged 480 "$merged_outcome" >/dev/null
jq -e '
  .outcome == "merged"
  and .request_id == "test-request-2"
  and .pull_request_number == 480
  and .workflow_run_id == 12346
  and .workflow_run_attempt == 2
' "$merged_outcome" >/dev/null

if GITHUB_REPOSITORY=markus-barta/nixcfg \
  GITHUB_RUN_ID=12347 \
  GITHUB_RUN_ATTEMPT=1 \
  "$outcome_writer" csb0 test-request-3 already_declared 481 \
  "$fixture_dir/invalid-outcome.json" >/dev/null 2>&1; then
  echo "already-declared outcome accepted a pull request number" >&2
  exit 1
fi

run_update() {
  PHAROS_SETTINGS_FILE="$fixture" \
    "$repo_root/scripts/update-pharos-host-settings.sh" "$@" >/dev/null
}

run_update hsb8 '#12AB34' workstation true false true test-request-1
jq -e '
  .hosts.hsb8 == {
    accent: "#12ab34",
    alerts: {
      suppress_backup: false,
      suppress_down: true,
      suppress_nix_freshness: true
    },
    kind: "workstation"
  }
' "$fixture" >/dev/null

before=$(jq -S . "$fixture")
if run_update hsb8 invalid server false false false test-request-2 2>/dev/null; then
  echo "invalid accent was accepted" >&2
  exit 1
fi
if run_update unknown '#123456' server false false false test-request-3 2>/dev/null; then
  echo "unknown host was accepted" >&2
  exit 1
fi
after=$(jq -S . "$fixture")
[[ "$before" == "$after" ]] || {
  echo "failed updates changed the registry" >&2
  exit 1
}

jq '.hosts.hsb8.unexpected = true' "$fixture" >"$fixture_dir/invalid.json"
if PHAROS_SETTINGS_FILE="$fixture_dir/invalid.json" \
  "$repo_root/scripts/update-pharos-host-settings.sh" \
  hsb8 '#123456' server false false false test-request-4 >/dev/null 2>&1; then
  echo "unknown registry field was accepted" >&2
  exit 1
fi

echo "pharos_host_preferences=passed"
