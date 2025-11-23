#!/usr/bin/env bash
#
# T07: Web Management Interface - Automated Test
# Tests that AdGuard Home web interface is accessible
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T07: Web Management Interface Test ==="
echo "Host: $HOST"
echo

# Test 1: Port 3000 listening
echo -n "Test 1: Port 3000 listening... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo ss -tlpn | grep -q ":3000"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Web interface accessible
echo -n "Test 2: Web interface accessible... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$HOST:3000" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $HTTP_CODE)"
  exit 1
fi

# Test 3: Firewall allows port 3000 (check iptables or configuration)
echo -n "Test 3: Firewall configured... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo iptables -L -n | grep -q "3000"' &>/dev/null ||
  ssh "$SSH_USER@$HOST" 'sudo nft list ruleset 2>/dev/null | grep -q "3000"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
