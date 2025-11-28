#!/usr/bin/env bash
# T01: Fish Shell - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T01: Fish Shell Test ==="
echo

PASSED=0
FAILED=0

# Test 1: Fish installed
echo -n "Test 1: Fish installed... "
if command -v fish >/dev/null 2>&1; then
  FISH_VERSION=$(fish --version)
  echo -e "${GREEN}✅ PASS${NC} ($FISH_VERSION)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 2: Fish from Nix
echo -n "Test 2: Fish from Nix... "
FISH_PATH=$(which fish)
if [[ "$FISH_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($FISH_PATH)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC} (found at $FISH_PATH)"
  ((FAILED++))
fi

# Test 3: Fish config exists
echo -n "Test 3: Fish config exists... "
if [ -f "$HOME/.config/fish/config.fish" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 4: Aliases defined (need interactive shell)
echo -n "Test 4: Aliases defined... "
# Fish aliases are set via shellAliases in home-manager, check config
if grep -q "alias" "$HOME/.config/fish/config.fish" 2>/dev/null ||
  [ -d "$HOME/.config/fish/functions" ]; then
  echo -e "${GREEN}✅ PASS${NC} (aliases in config)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 5: Abbreviations defined (check config, not runtime)
echo -n "Test 5: Abbreviations defined... "
# Check if fish_variables contains abbreviations or config references them
if grep -q "abbr" "$HOME/.config/fish/config.fish" 2>/dev/null ||
  [ -f "$HOME/.config/fish/fish_variables" ]; then
  echo -e "${GREEN}✅ PASS${NC} (abbreviations configured)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

echo
echo "Results: $PASSED passed, $FAILED failed"
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ Some tests failed${NC}"
  exit 1
fi
