#!/usr/bin/env bash
#
# T07: Web Management Interface - Automated Test
# Tests that AdGuard Home web interface is accessible
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
NC='\033[0m' # No Color

echo "=== T07: Web Management Interface Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Port 3000 listening
echo -n "Test 1: Port 3000 listening... "
if run 'sudo ss -tlpn | grep -q ":3000"'; then
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
if run 'sudo iptables -L -n | grep -q "3000"' ||
  run 'sudo nft list ruleset 2>/dev/null | grep -q "3000"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
