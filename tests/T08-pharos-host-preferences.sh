#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture_dir=$(mktemp -d)
fixture="$fixture_dir/pharos-host-preferences.json"
cp "$repo_root/modules/pharos-host-preferences.json" "$fixture"

jq -e '
  (.hosts | keys) == ["csb0", "csb1", "gpc0", "hsb0", "hsb1", "hsb8", "hsb9"]
' "$fixture" >/dev/null

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
