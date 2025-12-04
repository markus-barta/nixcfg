#!/usr/bin/env bash
#
# T00: NixOS Base System - Automated Test
# Tests that NixOS is properly installed and functioning on hsb1
#

set -euo pipefail

# Configuration
HOST="${HSB1_HOST:-192.168.1.101}"
SSH_USER="${HSB1_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T00: NixOS Base System Test ==="
echo "Host: $HOST"
echo

# Test 1: NixOS version
echo -n "Test 1: NixOS version... "
if VERSION=$(ssh "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null); then
  echo -e "${GREEN}✅ PASS${NC} ($VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Configuration directory exists
echo -n "Test 2: Configuration directory... "
if ssh "$SSH_USER@$HOST" 'test -d ~/nixcfg/hosts/hsb1' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Generations exist
echo -n "Test 3: System generations... "
GEN_COUNT=$(ssh "$SSH_USER@$HOST" 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
if [ "$GEN_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: System running
echo -n "Test 4: System status... "
STATUS=$(ssh "$SSH_USER@$HOST" 'systemctl is-system-running' 2>/dev/null || echo "unknown")
if [ "$STATUS" = "running" ] || [ "$STATUS" = "degraded" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATUS)"
else
  echo -e "${RED}❌ FAIL${NC} ($STATUS)"
  exit 1
fi

# Test 5: GRUB installed
echo -n "Test 5: GRUB bootloader... "
if ssh "$SSH_USER@$HOST" 'test -d /boot/grub' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
