#!/usr/bin/env bash
# T05: direnv + nix-direnv - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T05: direnv + nix-direnv Test ==="
echo

# Test 1: direnv installed
echo -n "Test 1: direnv installed... "
if command -v direnv >/dev/null 2>&1; then
  DIRENV_VERSION=$(direnv version)
  echo -e "${GREEN}✅ PASS${NC} ($DIRENV_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: direnv from Nix
echo -n "Test 2: direnv from Nix... "
DIRENV_PATH=$(which direnv)
if [[ "$DIRENV_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($DIRENV_PATH)"
else
  echo -e "${RED}❌ FAIL${NC} (found at $DIRENV_PATH)"
  exit 1
fi

# Test 3: direnv Fish integration
echo -n "Test 3: direnv Fish integration... "
if grep -q "direnv" "$HOME/.config/fish/config.fish" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
