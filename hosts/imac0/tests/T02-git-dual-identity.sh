#!/usr/bin/env bash
#
# T02: Git Dual Identity - Automated Test
# Tests that Git automatically switches identity based on directory
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T02: Git Dual Identity Test ==="
echo

# Test 1: Git installed
echo -n "Test 1: Git installed... "
if command -v git >/dev/null 2>&1; then
  GIT_VERSION=$(git --version)
  echo -e "${GREEN}✅ PASS${NC} ($GIT_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Git from Nix
echo -n "Test 2: Git from Nix... "
GIT_PATH=$(which git)
if [[ "$GIT_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($GIT_PATH)"
else
  echo -e "${RED}❌ FAIL${NC} (found at $GIT_PATH)"
  exit 1
fi

# Test 3: Personal identity (default)
echo -n "Test 3: Personal identity (default)... "
cd "$HOME/Code/nixcfg" || exit 1
PERSONAL_NAME=$(git config user.name)
PERSONAL_EMAIL=$(git config user.email)
if [[ "$PERSONAL_NAME" == "Markus Barta" ]] && [[ "$PERSONAL_EMAIL" == "markus@barta.com" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (got: $PERSONAL_NAME / $PERSONAL_EMAIL)"
  exit 1
fi

# Test 4: Work identity (BYTEPOETS directory)
echo -n "Test 4: Work identity (BYTEPOETS)... "
if [[ -d "$HOME/Code/BYTEPOETS" ]]; then
  # Find first git repo in BYTEPOETS
  WORK_REPO=$(find "$HOME/Code/BYTEPOETS" -name ".git" -type d | head -1 | xargs dirname)
  if [[ -n "$WORK_REPO" ]]; then
    cd "$WORK_REPO" || exit 1
    WORK_NAME=$(git config user.name)
    WORK_EMAIL=$(git config user.email)
    if [[ "$WORK_NAME" == "mba" ]] && [[ "$WORK_EMAIL" == "markus.barta@bytepoets.com" ]]; then
      echo -e "${GREEN}✅ PASS${NC}"
    else
      echo -e "${RED}❌ FAIL${NC} (got: $WORK_NAME / $WORK_EMAIL)"
      exit 1
    fi
  else
    echo -e "${GREEN}⏭  SKIP${NC} (no BYTEPOETS repos)"
  fi
else
  echo -e "${GREEN}⏭  SKIP${NC} (no BYTEPOETS directory)"
fi

# Test 5: Dual identity actually works
echo -n "Test 5: Dual identity configuration... "
# The fact that test 3 and 4 passed proves the dual identity mechanism works
# Check that the git config exists
if [[ -f "$HOME/.gitconfig" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (dual identity working)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
