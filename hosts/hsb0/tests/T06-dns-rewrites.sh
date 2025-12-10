#!/usr/bin/env bash
#
# T06: DNS Rewrites - Automated Test
# Tests that DNS rewrites are properly configured for csb0/csb1
#
# Can run locally on hsb0 OR remotely via SSH
#

set -euo pipefail

# Configuration
TARGET_HOST="hsb0"
HOST="${HSB0_HOST:-192.168.1.99}"

# Detect run mode for display
if [[ "$(hostname)" == "$TARGET_HOST" ]]; then
  RUN_MODE="local"
else
  RUN_MODE="remote"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T06: DNS Rewrites Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: csb0 DNS rewrite (check if it resolves via CNAME to cs0.barta.cm)
echo -n "Test 1: csb0 DNS resolution... "
if nslookup csb0 "$HOST" 2>/dev/null | grep -q "cs0.barta.cm"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: csb1 DNS rewrite (check if it resolves via CNAME to cs1.barta.cm)
echo -n "Test 2: csb1 DNS resolution... "
if nslookup csb1 "$HOST" 2>/dev/null | grep -q "cs1.barta.cm"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Internal hostname resolution (hsb0.lan)
echo -n "Test 3: Internal DNS resolution... "
if nslookup hsb0.lan "$HOST" 2>/dev/null | grep -q "192.168.1.99"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
