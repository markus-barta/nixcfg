#!/usr/bin/env bash
#
# T05: Static DHCP Leases - Automated Test
# Tests that static DHCP leases are properly managed via agenix
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T05: Static DHCP Leases Test ==="
echo "Host: $HOST"
echo

# Test 1: Agenix secret decrypted
echo -n "Test 1: Agenix secret decrypted... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'test -f /run/agenix/static-leases-hsb0' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Valid JSON format
echo -n "Test 2: Valid JSON format... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'jq empty /run/agenix/static-leases-hsb0' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Leases file exists
echo -n "Test 3: Leases file exists... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo test -f /var/lib/private/AdGuardHome/data/leases.json' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Static leases merged
echo -n "Test 4: Static leases merged... "
# shellcheck disable=SC2029
STATIC_COUNT=$(ssh "$SSH_USER@$HOST" 'sudo cat /var/lib/private/AdGuardHome/data/leases.json | jq "[.leases[] | select(.static == true)] | length"' 2>/dev/null || echo "0")
if [ "$STATIC_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATIC_COUNT static leases)"
else
  echo -e "${RED}❌ FAIL${NC} (No static leases found)"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
