#!/usr/bin/env bash
#
# T01: DNS Server - Automated Test
# Tests that AdGuard Home DNS is properly configured and resolving queries
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T01: DNS Server Test ==="
echo "Host: $HOST"
echo

# Test 1: AdGuard Home service running
echo -n "Test 1: AdGuard Home service... "
if ssh "$SSH_USER@$HOST" 'systemctl is-active adguardhome' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: DNS resolution (external)
echo -n "Test 2: External DNS resolution... "
if nslookup google.com "$HOST" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: DNS resolution (internal)
echo -n "Test 3: Internal DNS resolution... "
if RESULT=$(nslookup hsb0.lan "$HOST" 2>/dev/null) && echo "$RESULT" | grep -q "192.168.1.99"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: DNS port accessible
echo -n "Test 4: DNS port 53... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'ss -tulpn | grep -q ":53 "' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Upstream DNS configured
echo -n "Test 5: Upstream DNS config... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo systemctl cat adguardhome | grep -q "1.1.1.1"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
