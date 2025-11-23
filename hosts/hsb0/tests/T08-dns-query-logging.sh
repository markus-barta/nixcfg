#!/usr/bin/env bash
#
# T08: DNS Query Logging - Automated Test
# Tests that DNS query logging is properly configured
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T08: DNS Query Logging Test ==="
echo "Host: $HOST"
echo

# Test 1: Query logging enabled (check actual AdGuard config)
echo -n "Test 1: Query logging enabled... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -A10 "^querylog:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "enabled: true"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: 90-day retention configured (check actual AdGuard config)
echo -n "Test 2: 90-day retention (2160h)... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -A10 "^querylog:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "interval: 2160h"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Memory size configured (check actual AdGuard config)
echo -n "Test 3: Memory size (1000)... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -A10 "^querylog:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "size_memory: 1000"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
