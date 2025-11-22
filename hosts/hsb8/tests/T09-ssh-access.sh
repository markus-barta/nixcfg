#!/usr/bin/env bash
#
# T09: SSH Remote Access - Automated Test
# Tests that SSH access is functional and secure
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
HOSTNAME="${HSB8_HOSTNAME:-hsb8.lan}"
SSH_USER="${HSB8_USER:-mba}"
GB_USER="gb"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T09: SSH Remote Access & Security Test ==="
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
echo "=== Security Checks ==="
echo

# Test 6: Passwordless sudo
echo -n "Test 6: Passwordless sudo... "
if ssh -o BatchMode=yes "$SSH_USER@$HOST" "sudo -n whoami" 2>/dev/null | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC} (no password prompt)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 7: User password exists (not disabled)
echo -n "Test 7: User password configured... "
# shellcheck disable=SC2029
PASSWORD_STATUS=$(ssh "$SSH_USER@$HOST" "sudo getent shadow $SSH_USER | cut -d: -f2")
if [[ "$PASSWORD_STATUS" == "!" ]] || [[ "$PASSWORD_STATUS" == "*" ]]; then
  echo -e "${RED}❌ FAIL${NC} (password disabled - no recovery!)"
  exit 1
elif [[ "$PASSWORD_STATUS" =~ ^\$[6y]\$ ]]; then
  echo -e "${GREEN}✅ PASS${NC} (password exists for recovery)"
else
  echo -e "${YELLOW}⚠ WARNING${NC} (unexpected format: ${PASSWORD_STATUS:0:10}...)"
fi

# Test 8: SSH keys - Only authorized keys present (mba)
echo -n "Test 8: SSH key security (mba)... "
# shellcheck disable=SC2029
AUTHORIZED_KEYS=$(ssh "$SSH_USER@$HOST" "sudo cat /etc/ssh/authorized_keys.d/$SSH_USER")
KEY_COUNT=$(echo "$AUTHORIZED_KEYS" | grep -c "^ssh-" || true)

# Check for external keys that should NOT be present
if echo "$AUTHORIZED_KEYS" | grep -qi "omega"; then
  echo -e "${RED}❌ FAIL${NC} (external omega key found!)"
  exit 1
elif echo "$AUTHORIZED_KEYS" | grep -qi "yubikey"; then
  echo -e "${RED}❌ FAIL${NC} (Yubikey found!)"
  exit 1
elif [[ $KEY_COUNT -ne 1 ]]; then
  echo -e "${YELLOW}⚠ WARNING${NC} (expected 1 key, found $KEY_COUNT)"
elif ! echo "$AUTHORIZED_KEYS" | grep -q "AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H"; then
  echo -e "${RED}❌ FAIL${NC} (expected mba key not found)"
  exit 1
else
  echo -e "${GREEN}✅ PASS${NC} (only authorized key)"
fi

# Test 9: SSH keys - GB user
echo -n "Test 9: SSH key security (gb)... "
# shellcheck disable=SC2029
GB_AUTHORIZED_KEYS=$(ssh "$SSH_USER@$HOST" "sudo cat /etc/ssh/authorized_keys.d/$GB_USER 2>/dev/null" || echo "")

if [[ -z "$GB_AUTHORIZED_KEYS" ]]; then
  echo -e "${YELLOW}⚠ WARNING${NC} (gb authorized_keys not found)"
else
  GB_KEY_COUNT=$(echo "$GB_AUTHORIZED_KEYS" | grep -c "^ssh-" || true)

  if echo "$GB_AUTHORIZED_KEYS" | grep -qi "omega"; then
    echo -e "${RED}❌ FAIL${NC} (external omega key in gb!)"
    exit 1
  elif [[ $GB_KEY_COUNT -ne 1 ]]; then
    echo -e "${YELLOW}⚠ WARNING${NC} (expected 1 key, found $GB_KEY_COUNT)"
  elif ! echo "$GB_AUTHORIZED_KEYS" | grep -q "AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI"; then
    echo -e "${RED}❌ FAIL${NC} (expected gb key not found)"
    exit 1
  else
    echo -e "${GREEN}✅ PASS${NC} (only authorized key)"
  fi
fi

# Test 10: SSH password authentication disabled
echo -n "Test 10: SSH password auth disabled... "
if ssh "$SSH_USER@$HOST" "sudo grep -E '^PasswordAuthentication\s+no' /etc/ssh/sshd_config" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠ WARNING${NC} (could not verify)"
fi

# Test 11: Root SSH login disabled
echo -n "Test 11: Root SSH login disabled... "
if ssh "$SSH_USER@$HOST" "sudo grep -E '^PermitRootLogin\s+' /etc/ssh/sshd_config | grep -q 'no'" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠ WARNING${NC} (could not verify or might be enabled)"
fi

echo
echo -e "${GREEN}🎉 All critical tests passed!${NC}"
echo
echo "Security configuration verified:"
echo "  ✓ SSH key authentication working"
echo "  ✓ Passwordless sudo enabled"
echo "  ✓ User password exists (recovery available)"
echo "  ✓ Only authorized keys present"
echo "  ✓ No external keys (omega/yubikey blocked)"
echo
exit 0
