#!/usr/bin/env bash
#
# T16: User Identity Configuration - Automated Test
# Tests that user identity is correctly configured (not Patrizio defaults)
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T16: User Identity Configuration Test ==="
echo "Host: $HOST"
echo

# Test 1: Git user.name is set correctly
echo -n "Test 1: Git user.name (should be Markus Barta)... "
# shellcheck disable=SC2029
USER_NAME=$(ssh "$SSH_USER@$HOST" 'git config --get user.name' 2>/dev/null || echo "NOT SET")
if [ "$USER_NAME" = "Markus Barta" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (got: '$USER_NAME')"
  exit 1
fi

# Test 2: Git user.email is set correctly
echo -n "Test 2: Git user.email (should be markus@barta.com)... "
# shellcheck disable=SC2029
USER_EMAIL=$(ssh "$SSH_USER@$HOST" 'git config --get user.email' 2>/dev/null || echo "NOT SET")
if [ "$USER_EMAIL" = "markus@barta.com" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (got: '$USER_EMAIL')"
  exit 1
fi

# Test 3: Not using Patrizio's defaults
echo -n "Test 3: NOT using Patrizio defaults... "
if [ "$USER_NAME" != "Patrizio Bekerle" ] && [ "$USER_EMAIL" != "patrizio@bekerle.com" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (using Patrizio's defaults!)"
  exit 1
fi

# Test 4: Configuration has userNameLong
echo -n "Test 4: userNameLong configured... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "userNameLong.*Markus Barta" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Configuration has userEmail
echo -n "Test 5: userEmail configured... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "userEmail.*markus@barta.com" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
