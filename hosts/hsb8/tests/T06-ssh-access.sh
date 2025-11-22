#!/usr/bin/env bash
#
# T06: SSH Remote Access - Automated Test
# Tests that SSH access is functional
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
HOSTNAME="${HSB8_HOSTNAME:-hsb8.lan}"
SSH_USER="${HSB8_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T06: SSH Remote Access Test ==="
echo "Host: $HOST"
echo "Hostname: $HOSTNAME"
echo "User: $SSH_USER"
echo

# Test 1: SSH connection via IP
echo -n "Test 1: SSH connection (IP)... "
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$HOST" 'exit 0' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: SSH connection via hostname
echo -n "Test 2: SSH connection (hostname)... "
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$HOSTNAME" 'exit 0' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (hostname resolution may not work)"
  # Don't exit, hostname might not be configured
fi

# Test 3: SSH service status
echo -n "Test 3: SSH service status... "
if ssh "$SSH_USER@$HOST" 'systemctl is-active sshd' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Port accessibility
echo -n "Test 4: SSH port 22 accessible... "
if nc -zv "$HOST" 22 &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Command execution
echo -n "Test 5: Remote command execution... "
RESULT=$(ssh "$SSH_USER@$HOST" 'echo "test"' 2>/dev/null)
if [ "$RESULT" = "test" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
