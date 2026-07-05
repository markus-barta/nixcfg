#!/usr/bin/env bash
# T05-hostdash-manifest.sh
# Description: Validate generated HostDash/Pharos manifest for hsb8.
# Related PPM issues: NIX-277, NIX-278, NIX-279

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

pass() {
  echo -e "${GREEN}PASS${NC} $1"
  ((PASSED += 1))
}

fail() {
  echo -e "${RED}FAIL${NC} $1"
  ((FAILED += 1))
}

check_jq() {
  local label="$1"
  local expr="$2"

  if jq -e "$expr" >/dev/null <<<"$MANIFEST_JSON"; then
    pass "$label"
  else
    fail "$label"
  fi
}

cd "$REPO_ROOT"

echo "=== T05: HostDash manifest generation ==="
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for this test"
  exit 1
fi

MANIFEST_JSON="$(nix eval '.#nixosConfigurations.hsb8.config.services.hostdash.manifest.generated' --json 2>/dev/null)"
OUTPUT_PATH="$(nix eval '.#nixosConfigurations.hsb8.config.services.hostdash.manifest.effectiveOutputPath' --raw 2>/dev/null)"
SOURCE_PATH="$(nix eval '.#nixosConfigurations.hsb8.config.services.hostdash.manifest.source' --raw 2>/dev/null)"
ETC_SOURCE="$(nix eval '.#nixosConfigurations.hsb8.config.environment.etc."hostdash-config/hsb8.json".source' --raw 2>/dev/null)"

check_jq "schema is versioned" '.schema == "inspr.hostdash.config.v1" and .version == 1'
check_jq "host metadata is hsb8" '.host.name == "hsb8" and .host.fqdn == "hsb8.lan" and .host.ip == "192.168.1.100"'
check_jq "palette is exported from theme-palettes.nix" '.palette.name == "custom-hsb8" and (.palette.accent | test("^#[0-9a-fA-F]{6}$"))'
check_jq "all hsb8 service cards are declared" '.services | length == 6'
check_jq "AdGuard URL variants are present" '.services[] | select(.name == "AdGuard Home") | .urls.lanHostname == "http://hsb8.lan:3000/" and .urls.lanIp == "http://192.168.1.100:3000/" and .urls.tailnet == "http://hsb8:3000/"'
check_jq "Pharos owns runtime state" '.policy.declaredOnly == true and .policy.runtimeStateOwner == "pharos"'
check_jq "privileged actions are explicitly classified" '.policy.privilegedActions.mode == "none" and .policy.privilegedActions.janusRequired == false'

if [[ "$OUTPUT_PATH" == "hostdash-config/hsb8.json" ]]; then
  pass "effective output path is stable"
else
  fail "effective output path is stable: got $OUTPUT_PATH"
fi

if [[ "$SOURCE_PATH" == /nix/store/*hostdash-hsb8-config.json ]]; then
  pass "manifest source points to generated JSON"
else
  fail "manifest source points to generated JSON: got $SOURCE_PATH"
fi

if [[ "$ETC_SOURCE" == /nix/store/*hostdash-hsb8-config.json ]]; then
  pass "environment.etc points to generated JSON"
else
  fail "environment.etc points to generated JSON: got $ETC_SOURCE"
fi

echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
