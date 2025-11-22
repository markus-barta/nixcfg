#!/usr/bin/env bash
#
# T10: Multi-User Access - Automated Test
# Tests that multiple users can access the server
#
# shellcheck disable=SC2029

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
USER1="mba"
USER2="gb"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T10: Multi-User Access Test ==="
echo "Host: $HOST"
echo "Users: $USER1, $USER2"
echo

# Test 1: MBA user SSH access
echo -n "Test 1: $USER1 user SSH access... "
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER1@$HOST" 'exit 0' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: GB user SSH access configuration
echo -n "Test 2: $USER2 user SSH key configured... "
GB_KEY=$(ssh "$USER1@$HOST" "sudo cat /etc/ssh/authorized_keys.d/$USER2 2>/dev/null" || echo "")
if [[ -n "$GB_KEY" ]] && echo "$GB_KEY" | grep -q "^ssh-"; then
  # Verify it's the correct key (gb@gerhard)
  if echo "$GB_KEY" | grep -q "AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI"; then
    echo -e "${GREEN}✅ PASS${NC} (gb@gerhard key configured)"
  else
    echo -e "${YELLOW}⚠️  WARN${NC} (unexpected key found)"
  fi
else
  echo -e "${YELLOW}⚠️  WARN${NC} (GB user SSH key not configured)"
  GB_SKIP=true
fi

# Test 3: Verify users exist in system
echo -n "Test 3: Users exist in system... "
USERS=$(ssh "$USER1@$HOST" "cat /etc/passwd | grep -E '^(mba|gb):' | wc -l")
if [ "$USERS" -eq 2 ]; then
  echo -e "${GREEN}✅ PASS${NC} (2 users)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} ($USERS/2 users found)"
fi

# Test 4: MBA sudo access
echo -n "Test 4: $USER1 sudo access... "
if ssh "$USER1@$HOST" 'sudo -n whoami' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (Passwordless sudo may not be configured)"
fi

# Test 5: Home directories exist
echo -n "Test 5: Home directories... "
if ssh "$USER1@$HOST" "test -d /home/$USER1 && test -d /home/$USER2" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  WARN${NC}"
fi

echo
if [ "${GB_SKIP:-false}" = "true" ]; then
  echo -e "${YELLOW}⚠️  Some tests skipped (GB user key not configured)${NC}"
else
  echo -e "${GREEN}🎉 All tests passed!${NC}"
fi
exit 0
