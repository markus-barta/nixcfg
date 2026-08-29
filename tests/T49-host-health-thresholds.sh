#!/usr/bin/env bash
# NIX-281: declared host health thresholds reach HostDash and Pharos from one
# source of truth.
#
# The failure this guards against is two dashboards and the terminal status bar
# disagreeing about what "critical" means. StaSysMo's metric table is the
# source; lib/host-health-thresholds.nix derives the declared bands from it and
# modules/hostdash-manifest.nix emits them into the nixcfg-owned
# inspr.hostdash.config.v1 manifest, which HostDash reads directly and pharosd
# reads through PHAROS_MANIFEST_PATHS (NIX-286).
set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest_module="$repo_root/modules/hostdash-manifest.nix"

unit_result=$(nix eval --json --file "$repo_root/tests/host-health-thresholds-eval.nix")

# Every positive property and every rejection path must hold.
if ! jq -e '[.checks[]] | all' <<<"$unit_result" >/dev/null; then
  printf 'host_health_thresholds=failed reason=unit_checks failing=%s\n' \
    "$(jq -c '[.checks | to_entries[] | select(.value != true) | .key]' <<<"$unit_result")" >&2
  exit 1
fi

# Shape of the emitted document, so a consumer can rely on it.
jq -e '
  .server.schema == "inspr.hostdash.health-thresholds.v1"
  and .server.version == 1
  and .server.source == "stasysmo"
  and .server.class == "server"
  and .workstation.class == "workstation"
  and ((.server.metrics | keys) == ["cpu", "disk", "load", "ram", "swap"])
  and ([.server.metrics[] | .elevated < .critical] | all)
  and ([.workstation.metrics[] | .elevated < .critical] | all)
  and ([.server.metrics[] | has("suffix") and has("priority")] | all)
' <<<"$unit_result" >/dev/null

# Int-typed metrics must not carry binary-float noise (90 * 1.1 = 99.00000000000001).
if jq -e '[.workstation.metrics | .cpu, .disk, .ram, .swap | .elevated, .critical]
          | map(. != floor) | any' <<<"$unit_result" >/dev/null; then
  printf 'host_health_thresholds=failed reason=non_integer_int_metric\n' >&2
  exit 1
fi

# The manifest must actually carry the block; an unemitted document is prose.
[[ "$(grep -Fc 'health = healthThresholds;' "$manifest_module")" == 1 ]]
[[ "$(grep -Fc 'mkHealthThresholds = import ../lib/host-health-thresholds.nix;' "$manifest_module")" == 1 ]]
[[ "$(grep -Fc 'stasysmoConfig = import ./uzumaki/stasysmo/config.nix;' "$manifest_module")" == 1 ]]

# Both knobs must stay declared and typed, or "typed and documented" regresses.
grep -Fq 'healthClass = mkOption {' "$manifest_module"
grep -Fq 'thresholds = mkOption {' "$manifest_module"

# The class must default from declared host preferences, not a hardcoded guess.
grep -Fq 'declaredPreferences.kind or "server"' "$manifest_module"

# Null placeholders from the submodule must be stripped, else an unset bound
# would overwrite the class default with null and fail the band check.
grep -Fq 'declaredThresholdOverrides' "$manifest_module"

# Guard the SSOT: thresholds must be derived, never restated as literals here.
if grep -Eq '^\s*(elevated|critical)\s*=\s*[0-9]' "$repo_root/lib/host-health-thresholds.nix"; then
  printf 'host_health_thresholds=failed reason=literal_threshold_in_library\n' >&2
  exit 1
fi

printf 'host_health_thresholds=ok checks=%s\n' "$(jq -r '.checks | length' <<<"$unit_result")"
