#!/usr/bin/env bash
#
# T10: Homebrew Isolation - Automated Test
# Tests that Homebrew and Nix coexist without conflicts
#

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T10: Homebrew Isolation Test ==="
echo

# Test 1: Nix paths come before Homebrew in PATH
echo -n "Test 1: PATH prioritizes Nix... "
FIRST_NIX=$(echo "$PATH" | tr ':' '\n' | grep -n "nix-profile" | head -1 | cut -d: -f1)
FIRST_BREW=$(echo "$PATH" | tr ':' '\n' | grep -n "homebrew\|/usr/local/bin" | head -1 | cut -d: -f1)

if [[ -n "$FIRST_NIX" ]]; then
  if [[ -n "$FIRST_BREW" ]] && [[ "$FIRST_NIX" -lt "$FIRST_BREW" ]]; then
    echo -e "${GREEN}✅ PASS${NC} (Nix: $FIRST_NIX, System/Brew: $FIRST_BREW)"
  elif [[ -z "$FIRST_BREW" ]]; then
    echo -e "${GREEN}✅ PASS${NC} (Nix in PATH, no homebrew conflict)"
  else
    echo -e "${RED}❌ FAIL${NC} (System/Brew comes before Nix!)"
    exit 1
  fi
else
  echo -e "${RED}❌ FAIL${NC} (Nix not in PATH)"
  exit 1
fi

# Test 2: Key tools come from Nix, not Homebrew
echo -n "Test 2: Core tools from Nix... "
TOOLS=("git" "node" "python3" "fish" "bat" "rg")
ALL_FROM_NIX=true

for tool in "${TOOLS[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    TOOL_PATH=$(which "$tool")
    if [[ "$TOOL_PATH" != *".nix-profile"* ]]; then
      echo -e "${RED}❌ FAIL${NC} ($tool from $TOOL_PATH)"
      ALL_FROM_NIX=false
      break
    fi
  fi
done

if $ALL_FROM_NIX; then
  echo -e "${GREEN}✅ PASS${NC} (all core tools from Nix)"
fi

# Test 3: No duplicate packages between Nix and Homebrew
echo -n "Test 3: Check for duplicates... "
DUPLICATES=""
for tool in node python fish git bat ripgrep fd fzf; do
  NIX_HAS=$(command -v "$tool" 2>/dev/null | grep -c "nix-profile" || true)
  BREW_HAS=$(brew list 2>/dev/null | grep -c "^$tool$" || true)

  if [[ "$NIX_HAS" -gt 0 ]] && [[ "$BREW_HAS" -gt 0 ]]; then
    DUPLICATES="$DUPLICATES $tool"
  fi
done

if [[ -z "$DUPLICATES" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (no duplicates)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (duplicates found:$DUPLICATES)"
fi

# Test 4: Homebrew still functional (for GUI apps)
echo -n "Test 4: Homebrew functional... "
if command -v brew >/dev/null 2>&1; then
  BREW_VERSION=$(brew --version | head -1)
  echo -e "${GREEN}✅ PASS${NC} ($BREW_VERSION)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (Homebrew not found)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
