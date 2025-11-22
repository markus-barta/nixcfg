#!/usr/bin/env bash
#
# T06: DNS Rewrites - Automated Test
# Tests that DNS rewrites are properly configured for csb0/csb1
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T06: DNS Rewrites Test ==="
echo "Host: $HOST"
echo

# Test 1: Rewrite rules configured
echo -n "Test 1: Rewrite rules configured... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo systemctl cat adguardhome | grep -q "csb0"' &&
  ssh "$SSH_USER@$HOST" 'sudo systemctl cat adguardhome | grep -q "csb1"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: csb0 rewrite (check if it resolves)
echo -n "Test 2: csb0 DNS rewrite... "
if nslookup csb0 "$HOST" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: csb1 rewrite (check if it resolves)
echo -n "Test 3: csb1 DNS rewrite... "
if nslookup csb1 "$HOST" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
