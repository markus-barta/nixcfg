#!/usr/bin/env bash
#
# T17: Fish Shell Utilities - Automated Test
# Tests that fish shell functions (sourcefish) and EDITOR are configured
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T17: Fish Shell Utilities Test ==="
echo "Host: $HOST"
echo

# Test 1: sourcefish function exists
echo -n "Test 1: sourcefish function exists... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'type -q sourcefish' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: EDITOR variable is set to nano
echo -n "Test 2: EDITOR variable (should be nano)... "
# shellcheck disable=SC2029
EDITOR_VAR=$(ssh "$SSH_USER@$HOST" 'echo $EDITOR' 2>/dev/null || echo "NOT SET")
if [ "$EDITOR_VAR" = "nano" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (got: '$EDITOR_VAR')"
  exit 1
fi

# Test 3: sourcefish function works (load env var)
echo -n "Test 3: sourcefish function works... "
# shellcheck disable=SC2029
TEST_RESULT=$(ssh "$SSH_USER@$HOST" 'echo "TEST_VAR_T17=success_value" > /tmp/test-t17.env && sourcefish /tmp/test-t17.env && echo $TEST_VAR_T17' 2>/dev/null || echo "FAILED")
if [ "$TEST_RESULT" = "success_value" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (got: '$TEST_RESULT')"
  exit 1
fi

# Test 4: Configuration has sourcefish defined
echo -n "Test 4: sourcefish in configuration... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "function sourcefish" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Configuration has EDITOR export
echo -n "Test 5: EDITOR in configuration... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "export EDITOR=nano" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
