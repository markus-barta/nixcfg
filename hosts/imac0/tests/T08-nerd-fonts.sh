#!/usr/bin/env bash
#
# T08: Nerd Fonts - Automated Test
# Tests that Nerd Fonts are properly installed and available
#

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T08: Nerd Fonts Test ==="
echo

# Test 1: Font files exist in user library
echo -n "Test 1: Nerd Fonts in ~/Library/Fonts... "
if [[ -d "$HOME/Library/Fonts" ]] && find ~/Library/Fonts -name "*Nerd*" 2>/dev/null | grep -q .; then
  FONT_COUNT=$(find ~/Library/Fonts -name "*Nerd*" 2>/dev/null | wc -l | xargs)
  echo -e "${GREEN}✅ PASS${NC} ($FONT_COUNT font files)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Fonts are symlinked from Nix store
echo -n "Test 2: Fonts symlinked from Nix... "
# Check if any HackNerdFont files are symlinks to /nix/store
SYMLINK_COUNT=0
for font in ~/Library/Fonts/HackNerdFont*.ttf; do
  if [[ -L "$font" ]] && readlink "$font" | grep -q "/nix/store"; then
    ((SYMLINK_COUNT++))
  fi
done
if [[ "$SYMLINK_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC} (managed by Nix)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (not from Nix store)"
fi

# Test 3: Check if fonts are in macOS Font Book
echo -n "Test 3: Fonts registered in system... "
# Use system_profiler to list fonts
if system_profiler SPFontsDataType 2>/dev/null | grep -iq "hack"; then
  echo -e "${GREEN}✅ PASS${NC} (Hack font found)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (may need to restart apps)"
fi

# Test 4: WezTerm config references Nerd Font
echo -n "Test 4: WezTerm configured for Nerd Font... "
if [[ -f "$HOME/.config/wezterm/wezterm.lua" ]]; then
  if grep -iq "hack.*nerd" "$HOME/.config/wezterm/wezterm.lua"; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
else
  echo -e "${YELLOW}⚠️  SKIP${NC} (no wezterm config)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
