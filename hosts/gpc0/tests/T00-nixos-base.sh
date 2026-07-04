#!/usr/bin/env bash
#
# T00: NixOS Base System - Automated Test
# Tests that NixOS is properly installed and functioning on gpc0
#

set -euo pipefail

# Configuration
HOST="${GPC0_HOST:-192.168.1.154}"
SSH_USER="${GPC0_USER:-mba}"

# Run on-host or from a workstation: when executed on gpc0 itself, run
# checks directly instead of SSHing to ourselves (NIX-231).
if [ "$(hostname)" = "gpc0" ]; then
  run() { bash -c "$1"; }
  WHERE="local"
else
  # shellcheck disable=SC2029 # client-side expansion of $1 is the intent
  run() { ssh "$SSH_USER@$HOST" "$1"; }
  WHERE="ssh $SSH_USER@$HOST"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T00: NixOS Base System Test ==="
echo "Host: $HOST ($WHERE)"
echo

# Test 1: NixOS version
echo -n "Test 1: NixOS version... "
if VERSION=$(run 'nixos-version' 2>/dev/null); then
  echo -e "${GREEN}✅ PASS${NC} ($VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Configuration directory exists
echo -n "Test 2: Configuration directory... "
if run 'test -d ~/Code/nixcfg/hosts/gpc0' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Generations exist
echo -n "Test 3: System generations... "
GEN_COUNT=$(run 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
if [ "$GEN_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: System running
echo -n "Test 4: System status... "
STATUS=$(run 'systemctl is-system-running' 2>/dev/null || echo "unknown")
if [ "$STATUS" = "running" ] || [ "$STATUS" = "degraded" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATUS)"
else
  echo -e "${RED}❌ FAIL${NC} ($STATUS)"
  exit 1
fi

# Test 5: GRUB installed
echo -n "Test 5: GRUB bootloader... "
if run 'test -d /boot/grub' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
