#!/usr/bin/env bash
#
# T02: Ad Blocking - Automated Test
# Tests that AdGuard Home ad blocking is enabled
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T02: Ad Blocking Test ==="
echo "Host: $HOST"
echo

# Test 1: Protection enabled
echo -n "Test 1: Protection enabled... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo systemctl cat adguardhome | grep -q "protection_enabled.*true"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Filtering enabled
echo -n "Test 2: Filtering enabled... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo systemctl cat adguardhome | grep -q "filtering_enabled.*true"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: AdGuard Home web interface accessible
echo -n "Test 3: Web interface accessible... "
if curl -s -o /dev/null -w "%{http_code}" "http://$HOST:3000" | grep -q "200\|302"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
