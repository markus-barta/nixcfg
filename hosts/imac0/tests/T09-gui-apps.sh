#!/usr/bin/env bash
#
# T09: GUI Applications - Automated Test
# Tests that GUI apps are properly installed and accessible
#

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T09: GUI Applications Test ==="
echo

# Test 1: WezTerm in Home Manager Apps
echo -n "Test 1: WezTerm in Home Manager Apps... "
if [[ -d "$HOME/Applications/Home Manager Apps/WezTerm.app" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: WezTerm symlinked to main Applications
echo -n "Test 2: WezTerm in ~/Applications... "
if [[ -L "$HOME/Applications/WezTerm.app" ]]; then
  TARGET=$(readlink "$HOME/Applications/WezTerm.app")
  if [[ "$TARGET" == *"Home Manager Apps"* ]]; then
    echo -e "${GREEN}✅ PASS${NC} (symlinked)"
  else
    echo -e "${YELLOW}⚠️  WARN${NC} (not from Home Manager)"
  fi
else
  echo -e "${RED}❌ FAIL${NC}"
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
if mdfind "kMDItemKind == 'Application' && kMDItemFSName == 'WezTerm.app'" 2>/dev/null | grep -q "WezTerm.app"; then
  echo -e "${GREEN}✅ PASS${NC} (indexed by Spotlight)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (may need reindex)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
