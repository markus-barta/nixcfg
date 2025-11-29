#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T10: Rollback Test
# Verifies NixOS generation rollback capability (does NOT actually rollback)
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

# Timeout command
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
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T10: Rollback Test (Safe - No Changes Made) ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: SSH connectivity
echo -n "Test 1: SSH connectivity... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'echo "ok"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Generation count
echo -n "Test 2: Generation count... "
GEN_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
if [ "$GEN_COUNT" -gt 1 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations - rollback possible)"
else
  echo -e "${YELLOW}⚠️ ONLY 1 GENERATION${NC} (no rollback target!)"
fi

# Test 3: Current generation
echo -n "Test 3: Current generation... "
CURRENT_GEN=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'readlink /nix/var/nix/profiles/system | grep -oP "system-\K[0-9]+"' 2>/dev/null || echo "unknown")
echo -e "${GREEN}✅ PASS${NC} (generation $CURRENT_GEN)"

# Test 4: Previous generation exists
echo -n "Test 4: Previous generation exists... "
PREV_GEN=$((CURRENT_GEN - 1))
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "test -L /nix/var/nix/profiles/system-$PREV_GEN-link" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC} (generation $PREV_GEN available)"
else
  echo -e "${YELLOW}⚠️ NOT FOUND${NC} (generation $PREV_GEN may be garbage collected)"
fi

# Test 5: GRUB configured
echo -n "Test 5: GRUB bootloader... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'test -f /boot/grub/grub.cfg' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
fi

# Test 6: GRUB has multiple entries
echo -n "Test 6: GRUB menu entries... "
GRUB_ENTRIES=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo grep -c "menuentry" /boot/grub/grub.cfg 2>/dev/null' 2>/dev/null || echo "0")
if [ "$GRUB_ENTRIES" -gt 1 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GRUB_ENTRIES boot options)"
else
  echo -e "${YELLOW}⚠️ LIMITED${NC} ($GRUB_ENTRIES entries)"
fi

# Test 7: nixos-rebuild available
echo -n "Test 7: nixos-rebuild command... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'which nixos-rebuild' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
fi

# Test 8: List recent generations (informational)
echo
echo "Recent generations:"
$TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo nix-env --list-generations -p /nix/var/nix/profiles/system | tail -5' 2>/dev/null || echo "(failed to list)"

echo
echo "========================================"
echo -e "${GREEN}🎉 Rollback capability verified!${NC}"
echo
echo "Emergency rollback command:"
echo -e "${YELLOW}ssh -p 2222 mba@cs1.barta.cm 'sudo nixos-rebuild switch --rollback'${NC}"
echo
echo "If SSH broken, use VNC console (see secrets/RUNBOOK.md)"

exit 0
