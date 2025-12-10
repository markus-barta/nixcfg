#!/usr/bin/env bash
# T02: Git Dual Identity - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T02: Git Dual Identity Test ==="
echo

PASSED=0
FAILED=0

# Test 1: Git installed
echo -n "Test 1: Git installed... "
if command -v git >/dev/null 2>&1; then
  GIT_VERSION=$(git --version)
  echo -e "${GREEN}✅ PASS${NC} ($GIT_VERSION)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 2: Git from Nix
echo -n "Test 2: Git from Nix... "
GIT_PATH=$(which git)
if [[ "$GIT_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($GIT_PATH)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC} (found at $GIT_PATH)"
  ((FAILED++))
fi

# Test 3: Default identity is work
echo -n "Test 3: Default identity (work)... "
cd /tmp
DEFAULT_EMAIL=$(git config --global user.email 2>/dev/null || echo "not set")
if [[ "$DEFAULT_EMAIL" == "markus.barta@bytepoets.com" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($DEFAULT_EMAIL)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC} (got: $DEFAULT_EMAIL)"
  ((FAILED++))
fi

# Test 4: nixcfg identity is personal
echo -n "Test 4: nixcfg identity (personal)... "
if [ -d "$HOME/Code/nixcfg/.git" ]; then
  cd "$HOME/Code/nixcfg"
  NIXCFG_EMAIL=$(git config user.email 2>/dev/null || echo "not set")
  if [[ "$NIXCFG_EMAIL" == "markus@barta.com" ]]; then
    echo -e "${GREEN}✅ PASS${NC} ($NIXCFG_EMAIL)"
    ((PASSED++))
  else
    echo -e "${RED}❌ FAIL${NC} (got: $NIXCFG_EMAIL)"
    ((FAILED++))
  fi
else
  echo -e "${GREEN}✅ PASS${NC} (nixcfg not a git repo here, skipped)"
  ((PASSED++))
fi

# Test 5: Git config file exists
echo -n "Test 5: Git config exists... "
if [ -f "$HOME/.config/git/config" ] || [ -f "$HOME/.gitconfig" ]; then
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
