#!/usr/bin/env bash
#
# T19: Agenix Secret Management - Automated Test
# Tests that agenix is properly configured for encrypted secret management
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T19: Agenix Secret Management Test ==="
echo "Host: $HOST"
echo

# Test 1: Agenix CLI available
echo -n "Test 1: Agenix CLI available... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'which agenix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: rage encryption tool available
echo -n "Test 2: rage encryption tool available... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'which rage' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Secret file exists in repository
echo -n "Test 3: Secret file in repository... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'test -f ~/nixcfg/secrets/static-leases-hsb8.age' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: hsb8 host key in secrets.nix
echo -n "Test 4: hsb8 host key configured... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "hsb8 =" ~/nixcfg/secrets/secrets.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Static leases reference in secrets.nix
echo -n "Test 5: Static leases configured in secrets.nix... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "static-leases-hsb8.age" ~/nixcfg/secrets/secrets.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
echo
echo "Note: Secret decryption test skipped (requires DHCP enabled + system activation)"
echo "To test decryption after enabling DHCP:"
echo "  ssh $SSH_USER@$HOST 'test -f /run/agenix/static-leases-hsb8 && echo \"✅ Decrypted\"'"
exit 0
