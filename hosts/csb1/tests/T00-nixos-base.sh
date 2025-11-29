#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# T00: NixOS Base System - Automated Test
# Tests that NixOS is properly installed and functioning on csb1
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"

# SSH options with timeout
SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

# Timeout command (use gtimeout on macOS if available, otherwise skip)
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
NC='\033[0m' # No Color

echo "=== T00: NixOS Base System Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: NixOS version
echo -n "Test 1: NixOS version... "
if VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null); then
  echo -e "${GREEN}✅ PASS${NC} ($VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Configuration directory exists
echo -n "Test 2: Configuration directory... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'test -d ~/nixcfg/hosts/csb1' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Generations exist
echo -n "Test 3: System generations... "
GEN_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
if [ "$GEN_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: System running
echo -n "Test 4: System status... "
STATUS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'systemctl is-system-running' 2>/dev/null || echo "unknown")
if [ "$STATUS" = "running" ] || [ "$STATUS" = "degraded" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATUS)"
else
  echo -e "${RED}❌ FAIL${NC} ($STATUS)"
  exit 1
fi

# Test 5: Docker installed
echo -n "Test 5: Docker installed... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'which docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
