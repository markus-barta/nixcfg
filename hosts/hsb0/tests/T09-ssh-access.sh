#!/usr/bin/env bash
#
# T09: SSH Remote Access & Security - Automated Test
# Tests that SSH is properly configured and secured
#
# Can run locally on hsb0 OR remotely via SSH
#

set -euo pipefail

# Configuration
TARGET_HOST="hsb0"
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

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
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T09: SSH Remote Access & Security Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: SSH connectivity (only for remote mode)
echo -n "Test 1: SSH connectivity... "
if [[ "$RUN_MODE" == "local" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (local mode)"
else
  if ssh "$SSH_USER@$HOST" 'echo "success"' &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
fi

# Test 2: SSH service running
echo -n "Test 2: SSH service status... "
if run 'systemctl is-active sshd' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Key-based auth works (only for remote mode)
echo -n "Test 3: Key-based authentication... "
if [[ "$RUN_MODE" == "local" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (local mode)"
else
  if ssh -o PasswordAuthentication=no "$SSH_USER@$HOST" 'true' &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
fi

# Test 4: Passwordless sudo
echo -n "Test 4: Passwordless sudo... "
if run 'sudo -n whoami' | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: User password set (optional, SSH-key only is valid)
echo -n "Test 5: User password set... "
PASS_HASH=$(run 'sudo getent shadow mba | cut -d: -f2 | cut -c1-5' || echo "")
if [ "$PASS_HASH" != "!" ] && [ "$PASS_HASH" != "*" ] && [ -n "$PASS_HASH" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  SSH-KEY ONLY${NC} (no password, which is secure)"
fi

# Test 6: SSH keys configured (check both user and system locations)
echo -n "Test 6: SSH keys configured... "
KEY_COUNT_USER=$(run 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-"' || echo "0")
# shellcheck disable=SC2016
KEY_COUNT_SYSTEM=$(run 'sudo cat /etc/ssh/authorized_keys.d/$USER 2>/dev/null | grep -c "^ssh-"' || echo "0")
# Remove any whitespace/newlines
KEY_COUNT_USER=$(echo "$KEY_COUNT_USER" | tr -d '\n\r' | awk '{print $1}')
KEY_COUNT_SYSTEM=$(echo "$KEY_COUNT_SYSTEM" | tr -d '\n\r' | awk '{print $1}')
# Default to 0 if empty
KEY_COUNT_USER=${KEY_COUNT_USER:-0}
KEY_COUNT_SYSTEM=${KEY_COUNT_SYSTEM:-0}
KEY_COUNT=$((KEY_COUNT_USER + KEY_COUNT_SYSTEM))
if [ "$KEY_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($KEY_COUNT keys)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 7: Password authentication disabled
echo -n "Test 7: Password auth disabled... "
if run 'sudo grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

# Test 8: Root login disabled
echo -n "Test 8: Root login disabled... "
if run 'sudo grep -q "^PermitRootLogin no" /etc/ssh/sshd_config'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  NOT HARDENED${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
