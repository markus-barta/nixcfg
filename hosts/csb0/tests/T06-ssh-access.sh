#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T06: SSH Remote Access & Security Test
# Tests SSH access and security hardening
#

set -euo pipefail

HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_USER="${CSB0_USER:-mba}"
SSH_PORT="${CSB0_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"

SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout $CMD_TIMEOUT"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout $CMD_TIMEOUT"
else
  TIMEOUT_CMD=""
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T06: SSH Remote Access & Security Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

FAILURES=0

# Pre-Test: Port 2222 reachable (TCP check before SSH)
echo -n "Pre-test: Port $SSH_PORT reachable... "
if nc -z -w 5 "$HOST" "$SSH_PORT" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL - Port $SSH_PORT blocked (firewall?)${NC}"
  echo "⚠️  Check networking.firewall.allowedTCPPorts includes $SSH_PORT"
  ((FAILURES++))
fi

# Test 1: SSH connectivity
echo -n "Test 1: SSH connectivity... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'echo "success"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: SSH service status
echo -n "Test 2: SSH service status... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-active sshd' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 3: Key-based authentication
echo -n "Test 3: Key-based authentication... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS -o PasswordAuthentication=no "$SSH_USER@$HOST" 'true' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 4: Passwordless sudo
echo -n "Test 4: Passwordless sudo... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo -n whoami' 2>/dev/null | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 5: SSH keys configured
echo -n "Test 5: SSH keys configured... "
KEY_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-" || echo 0' 2>/dev/null | tr -d '\n\r')
if [[ "$KEY_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($KEY_COUNT keys)"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 6: No external omega keys (CRITICAL after hokage migration)
echo -n "Test 6: No external omega keys... "
OMEGA_KEYS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "omega" || echo 0' 2>/dev/null | tr -d '\n\r')
if [[ "$OMEGA_KEYS" -eq 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ WARNING${NC} ($OMEGA_KEYS omega keys found - check lib.mkForce)"
fi

# Test 7: Password auth disabled (should be after migration)
echo -n "Test 7: Password auth disabled... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

# Test 8: Root login disabled
echo -n "Test 8: Root login disabled... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo grep -q "^PermitRootLogin no" /etc/ssh/sshd_config' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  CHECK${NC}"
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAILURES test(s) failed${NC}"
  exit 1
fi
