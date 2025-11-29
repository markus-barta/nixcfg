#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# T06: SSH Remote Access & Security - Automated Test
# Tests that SSH is properly configured and secured
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
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T06: SSH Remote Access & Security Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: SSH connectivity
echo -n "Test 1: SSH connectivity... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'echo "success"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: SSH service running
echo -n "Test 2: SSH service status... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-active sshd' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Key-based auth works
echo -n "Test 3: Key-based authentication... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS -o PasswordAuthentication=no "$SSH_USER@$HOST" 'true' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Passwordless sudo
echo -n "Test 4: Passwordless sudo... "
# shellcheck disable=SC2029,SC2086
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo -n whoami' 2>/dev/null | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: SSH keys configured
echo -n "Test 5: SSH keys configured... "
# shellcheck disable=SC2029,SC2086
KEY_COUNT_USER=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-"' 2>/dev/null || echo "0")
# shellcheck disable=SC2029,SC2086
KEY_COUNT_SYSTEM=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "sudo cat /etc/ssh/authorized_keys.d/\$USER 2>/dev/null | grep -c \"^ssh-\"" 2>/dev/null || echo "0")
KEY_COUNT_USER=$(echo "$KEY_COUNT_USER" | tr -d '\n\r' | awk '{print $1}')
KEY_COUNT_SYSTEM=$(echo "$KEY_COUNT_SYSTEM" | tr -d '\n\r' | awk '{print $1}')
KEY_COUNT_USER=${KEY_COUNT_USER:-0}
KEY_COUNT_SYSTEM=${KEY_COUNT_SYSTEM:-0}
KEY_COUNT=$((KEY_COUNT_USER + KEY_COUNT_SYSTEM))
if [ "$KEY_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($KEY_COUNT keys)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 6: No omega keys (security check for hokage migration)
echo -n "Test 6: No external omega keys... "
# shellcheck disable=SC2029,SC2086
OMEGA_KEYS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "omega" || echo 0' 2>/dev/null | tr -d '\n\r')
OMEGA_KEYS=${OMEGA_KEYS:-0}
if [ "$OMEGA_KEYS" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ SECURITY ISSUE${NC} ($OMEGA_KEYS omega keys found!)"
  echo "⚠️  External omega keys detected - see MIGRATION-PLAN-HOKAGE.md for fix"
fi

# Test 7: Password authentication disabled
echo -n "Test 7: Password auth disabled... "
# shellcheck disable=SC2029,SC2086
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

# Test 8: Root login disabled
echo -n "Test 8: Root login disabled... "
# shellcheck disable=SC2029,SC2086
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo grep -q "^PermitRootLogin no" /etc/ssh/sshd_config' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
