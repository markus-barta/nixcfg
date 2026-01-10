#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T00: NixOS Base System Test
# Tests basic NixOS functionality
#

set -euo pipefail

# Configuration
HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_USER="${CSB0_USER:-mba}"
SSH_PORT="${CSB0_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"

# SSH options with timeout
SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# Timeout command (compatible with macOS and Linux)
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout $CMD_TIMEOUT"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout $CMD_TIMEOUT"
else
  TIMEOUT_CMD=""
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T00: NixOS Base System Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

FAILURES=0

# Test 1: NixOS version
echo -n "Test 1: NixOS version... "
VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null || echo "FAIL")
if [[ "$VERSION" != "FAIL" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: Configuration directory
echo -n "Test 2: Configuration directory... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'test -d /etc/nixos || test -d ~/nixcfg' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 3: System generations
echo -n "Test 3: System generations... "
GEN_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
if [[ "$GEN_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations)"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 4: System status
echo -n "Test 4: System status... "
SYS_STATE=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-system-running 2>/dev/null || echo "unknown"' 2>/dev/null)
if [[ "$SYS_STATE" == "running" ]] || [[ "$SYS_STATE" == "degraded" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($SYS_STATE)"
else
  echo -e "${RED}❌ FAIL${NC} ($SYS_STATE)"
  ((FAILURES++))
fi

# Test 5: Docker installed
echo -n "Test 5: Docker installed... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'which docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAILURES test(s) failed${NC}"
  exit 1
fi
