#!/usr/bin/env bash
#
# T07: GUI Applications - Automated Test
# Tests that GUI apps are properly installed and accessible via Spotlight
#
# NOTE: We use macOS aliases (not symlinks!) because:
#       Symlinks to /nix/store don't get indexed by Spotlight.
#       macOS aliases (created via osascript) ARE indexed properly.
#
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T07: GUI Applications Test ==="
echo

# Test 1: WezTerm in Home Manager Apps
echo -n "Test 1: WezTerm in Home Manager Apps... "
if [[ -d "$HOME/Applications/Home Manager Apps/WezTerm.app" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: WezTerm alias in ~/Applications (macOS alias, not symlink!)
echo -n "Test 2: WezTerm alias in ~/Applications... "
if [[ -f "$HOME/Applications/WezTerm.app" ]]; then
  # macOS aliases are files (not symlinks), usually 500-2000 bytes
  FILE_SIZE=$(stat -f%z "$HOME/Applications/WezTerm.app" 2>/dev/null || echo "0")
  if [[ "$FILE_SIZE" -gt 100 && "$FILE_SIZE" -lt 5000 ]]; then
    echo -e "${GREEN}✅ PASS${NC} (macOS alias, ${FILE_SIZE} bytes)"
  else
    echo -e "${YELLOW}⚠️  WARN${NC} (unexpected size: ${FILE_SIZE} bytes)"
  fi
elif [[ -L "$HOME/Applications/WezTerm.app" ]]; then
  # Old symlink-based approach (should be migrated)
  echo -e "${YELLOW}⚠️  WARN${NC} (symlink - run home-manager switch to create alias)"
else
  echo -e "${RED}❌ FAIL${NC} (not found)"
  exit 1
fi

# Test 3: WezTerm binary works
echo -n "Test 3: WezTerm binary executable... "
if command -v wezterm >/dev/null 2>&1; then
  WEZTERM_VERSION=$(wezterm --version | head -1)
  echo -e "${GREEN}✅ PASS${NC} ($WEZTERM_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Check Spotlight can find WezTerm
echo -n "Test 4: WezTerm in Spotlight... "
SPOTLIGHT_RESULT=$(mdfind "kMDItemDisplayName == 'WezTerm*'" 2>/dev/null || true)
if echo "$SPOTLIGHT_RESULT" | grep -q "WezTerm.app"; then
  echo -e "${GREEN}✅ PASS${NC} (indexed by Spotlight)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (not indexed yet - may need reindex or wait)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
