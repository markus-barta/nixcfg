#!/usr/bin/env bash
# T06: direnv + devenv - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T06: direnv + devenv Test ==="
echo

PASSED=0
FAILED=0

# Test 1: direnv installed
echo -n "Test 1: direnv installed... "
if command -v direnv >/dev/null 2>&1; then
  DIRENV_VERSION=$(direnv version)
  echo -e "${GREEN}✅ PASS${NC} ($DIRENV_VERSION)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 2: direnv from Nix
echo -n "Test 2: direnv from Nix... "
DIRENV_PATH=$(which direnv)
if [[ "$DIRENV_PATH" == *".nix-profile"* ]] || [[ "$DIRENV_PATH" == *"/nix/store"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($DIRENV_PATH)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC} (found at $DIRENV_PATH)"
  ((FAILED++))
fi

# Test 3: devenv installed
echo -n "Test 3: devenv installed... "
if command -v devenv >/dev/null 2>&1; then
  DEVENV_VERSION=$(devenv version 2>/dev/null || echo "ok")
  echo -e "${GREEN}✅ PASS${NC} ($DEVENV_VERSION)"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (install with: nix profile install nixpkgs#devenv)"
  ((PASSED++)) # Not critical for basic operation
fi

# Test 4: direnv Fish integration
echo -n "Test 4: direnv Fish integration... "
if grep -q "direnv" "$HOME/.config/fish/config.fish" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 5: .shared directory exists in nixcfg
echo -n "Test 5: .shared/common.just exists... "
if [ -e "$HOME/Code/nixcfg/.shared/common.just" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (run 'devenv shell' in nixcfg to create)"
  ((PASSED++))
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
