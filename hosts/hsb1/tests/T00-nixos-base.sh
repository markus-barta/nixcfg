#!/usr/bin/env bash
#
# T00: NixOS Base System - Automated Test
# Tests that NixOS is properly installed and functioning on hsb1
#
# Can run locally on hsb1 OR remotely via SSH
#

set -euo pipefail

# Configuration
TARGET_HOST="hsb1"
HOST="${HSB1_HOST:-192.168.1.101}"
SSH_USER="${HSB1_USER:-mba}"

# Detect if running locally on target host
if [[ "$(hostname)" == "$TARGET_HOST" ]]; then
  run() { eval "$1"; }
  RUN_MODE="local"
else
  # shellcheck disable=SC2029
  run() { ssh "$SSH_USER@$HOST" "$1" 2>/dev/null; }
  RUN_MODE="remote"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T00: NixOS Base System Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: NixOS version
echo -n "Test 1: NixOS version... "
if VERSION=$(run 'nixos-version'); then
  echo -e "${GREEN}✅ PASS${NC} ($VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Configuration directory exists
echo -n "Test 2: Configuration directory... "
if run 'test -d ~/Code/nixcfg/hosts/hsb1'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Generations exist
echo -n "Test 3: System generations... "
GEN_COUNT=$(run 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' || echo "0")
if [ "$GEN_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: System running
echo -n "Test 4: System status... "
STATUS=$(run 'systemctl is-system-running' || echo "unknown")
if [ "$STATUS" = "running" ] || [ "$STATUS" = "degraded" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATUS)"
else
  echo -e "${RED}❌ FAIL${NC} ($STATUS)"
  exit 1
fi

# Test 5: GRUB installed
echo -n "Test 5: GRUB bootloader... "
if run 'test -d /boot/grub'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
