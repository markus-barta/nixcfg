#!/usr/bin/env bash
# T03: Starship Prompt - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T03: Starship Prompt Test ==="
echo

PASSED=0
FAILED=0

# Test 1: Starship installed
echo -n "Test 1: Starship installed... "
if command -v starship >/dev/null 2>&1; then
  STARSHIP_VERSION=$(starship --version | head -1)
  echo -e "${GREEN}✅ PASS${NC} ($STARSHIP_VERSION)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 2: Starship from Nix
echo -n "Test 2: Starship from Nix... "
STARSHIP_PATH=$(which starship)
if [[ "$STARSHIP_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($STARSHIP_PATH)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC} (found at $STARSHIP_PATH)"
  ((FAILED++))
fi

# Test 3: Config file exists
echo -n "Test 3: Config file exists... "
if [ -f "$HOME/.config/starship.toml" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 4: Config is valid TOML
echo -n "Test 4: Config is valid... "
if starship config 2>/dev/null | head -1 >/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
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
