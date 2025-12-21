#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          Theme Color Wiring Test - P7200 / P2900 Validation                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# This test validates that NIXFLEET_THEME_COLOR is correctly wired from
# theme-palettes.nix to services.nixfleet-agent.themeColor for both:
#   - NixOS hosts (system-level agent via uzumaki/default.nix)
#   - macOS hosts (Home Manager agent via each host's home.nix)
#
# Run from nixcfg root: ./tests/test-theme-color-wiring.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Theme Color Wiring Test                                   ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

# Test function
test_host() {
  local host="$1"
  local type="$2"             # "nixos" or "hm"
  local expected_pattern="$3" # regex pattern for expected color (e.g., "#[0-9a-fA-F]{6}")

  echo -n "Testing $host ($type): "

  local result
  local exit_code=0

  if [ "$type" = "nixos" ]; then
    result=$(nix eval ".#nixosConfigurations.${host}.config.services.nixfleet-agent.themeColor" --json 2>/dev/null) || exit_code=$?
  else
    result=$(nix eval ".#homeConfigurations.${host}.config.services.nixfleet-agent.themeColor" --json 2>/dev/null) || exit_code=$?
  fi

  if [ $exit_code -ne 0 ]; then
    echo "❌ FAIL - eval error"
    ((FAIL++))
    return
  fi

  # Remove quotes from JSON string
  result=$(echo "$result" | tr -d '"')

  if [[ -z "$result" || "$result" == "null" ]]; then
    echo "❌ FAIL - empty or null"
    ((FAIL++))
    return
  fi

  if [[ "$result" =~ $expected_pattern ]]; then
    echo "✅ PASS - $result"
    ((PASS++))
  else
    echo "❌ FAIL - unexpected value: $result"
    ((FAIL++))
  fi
}

echo "─────────────────────────────────────────────────────────────────────────────"
echo "NixOS Hosts (system-level agent, wired via uzumaki/default.nix)"
echo "─────────────────────────────────────────────────────────────────────────────"

# NixOS hosts - expect 6-digit hex color
HEX_PATTERN='^#[0-9a-fA-F]{6}$'

test_host "csb0" "nixos" "$HEX_PATTERN"
test_host "csb1" "nixos" "$HEX_PATTERN"
test_host "hsb0" "nixos" "$HEX_PATTERN"
test_host "hsb1" "nixos" "$HEX_PATTERN"
test_host "hsb8" "nixos" "$HEX_PATTERN"
test_host "gpc0" "nixos" "$HEX_PATTERN"

echo ""
echo "─────────────────────────────────────────────────────────────────────────────"
echo "macOS Hosts (Home Manager agent, wired via each host's home.nix)"
echo "─────────────────────────────────────────────────────────────────────────────"

test_host "imac0" "hm" "$HEX_PATTERN"
test_host "mba-mbp-work" "hm" "$HEX_PATTERN"
test_host "mba-imac-work" "hm" "$HEX_PATTERN"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Summary: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "⚠️  Some tests failed. Check the output above for details."
  exit 1
else
  echo ""
  echo "✅ All theme color wiring tests passed!"
  exit 0
fi
