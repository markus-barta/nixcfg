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

# Test 1: Configuration has sourcefish defined
echo -n "Test 1: sourcefish in configuration... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "function sourcefish" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Configuration has EDITOR setting
echo -n "Test 2: EDITOR in configuration... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "set -gx EDITOR nano" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: sourcefish function exists in /etc/fish/config.fish
echo -n "Test 3: sourcefish in /etc/fish/config.fish... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "function sourcefish" /etc/fish/config.fish' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: EDITOR set in /etc/fish/config.fish
echo -n "Test 4: EDITOR in /etc/fish/config.fish... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "set -gx EDITOR nano" /etc/fish/config.fish' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: programs.fish.interactiveShellInit is set
echo -n "Test 5: programs.fish.interactiveShellInit set... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "programs.fish.interactiveShellInit" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
