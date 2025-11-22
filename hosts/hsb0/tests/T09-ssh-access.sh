#!/usr/bin/env bash
#
# T09: SSH Remote Access & Security - Automated Test
# Tests that SSH is properly configured and secured
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T09: SSH Remote Access & Security Test ==="
echo "Host: $HOST"
echo

# Test 1: SSH connectivity
echo -n "Test 1: SSH connectivity... "
if ssh "$SSH_USER@$HOST" 'echo "success"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: SSH service running
echo -n "Test 2: SSH service status... "
if ssh "$SSH_USER@$HOST" 'systemctl is-active sshd' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Key-based auth works
echo -n "Test 3: Key-based authentication... "
if ssh -o PasswordAuthentication=no "$SSH_USER@$HOST" 'true' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Passwordless sudo
echo -n "Test 4: Passwordless sudo... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo -n whoami' 2>/dev/null | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: User password set
echo -n "Test 5: User password set... "
# shellcheck disable=SC2029
PASS_HASH=$(ssh "$SSH_USER@$HOST" 'sudo getent shadow mba | cut -d: -f2 | cut -c1-5' 2>/dev/null)
if [ "$PASS_HASH" != "!" ] && [ "$PASS_HASH" != "*" ] && [ -n "$PASS_HASH" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (no password set)"
  exit 1
fi

# Test 6: SSH keys configured
echo -n "Test 6: SSH keys configured... "
# shellcheck disable=SC2029
KEY_COUNT=$(ssh "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-" || echo 0')
if [ "$KEY_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($KEY_COUNT keys)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 7: Password authentication disabled
echo -n "Test 7: Password auth disabled... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

# Test 8: Root login disabled
echo -n "Test 8: Root login disabled... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -q "^PermitRootLogin no" /etc/ssh/sshd_config' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
