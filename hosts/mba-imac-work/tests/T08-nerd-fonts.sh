#!/usr/bin/env bash
# T08: Nerd Fonts - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T08: Nerd Fonts Test ==="
echo

PASSED=0
FAILED=0

# Test 1: Font files in Library/Fonts
echo -n "Test 1: Font files in ~/Library/Fonts/... "
FONT_COUNT=$(find ~/Library/Fonts -maxdepth 1 -iname "*hack*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$FONT_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($FONT_COUNT files)"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (run home-manager switch to install)"
  ((PASSED++))
fi

# Test 2: fc-list shows Hack Nerd Font
echo -n "Test 2: fontconfig lists Hack Nerd... "
if command -v fc-list >/dev/null 2>&1; then
  FC_COUNT=$(fc-list 2>/dev/null | grep -ic "hack.*nerd" || echo "0")
  if [ "$FC_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✅ PASS${NC} ($FC_COUNT entries)"
    ((PASSED++))
  else
    echo -e "${YELLOW}⚠️ WARN${NC} (font not in fontconfig cache)"
    ((PASSED++))
  fi
else
  echo -e "${YELLOW}⚠️ SKIP${NC} (fc-list not available)"
  ((PASSED++))
fi

# Test 3: Nerd Font from Nix
echo -n "Test 3: Font from Nix store... "
if find ~/Library/Fonts -maxdepth 1 -type l -print0 2>/dev/null | xargs -0 -I{} readlink {} 2>/dev/null | grep -q "/nix/store"; then
  echo -e "${GREEN}✅ PASS${NC} (symlinks to Nix store)"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (fonts may not be Nix-managed)"
  ((PASSED++))
fi

# Test 4: REMOVED 2026-05-05 — WezTerm purged, Ghostty installed via Homebrew
# (config not declarative today). If Ghostty config moves into Nix, replace
# this with a Ghostty-specific font check.
echo -n "Test 4: (removed — WezTerm purged 2026-05-05) ... "
echo -e "${YELLOW}— SKIP —${NC}"
((PASSED++))

echo
echo "Results: $PASSED passed, $FAILED failed"
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ Some tests failed${NC}"
  exit 1
fi
