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

echo "=== T06: DNS Rewrites Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Rewrite rules configured (check actual AdGuard config user_rules)
echo -n "Test 1: Rewrite rules configured... "
if run 'sudo grep -A5 "user_rules:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "csb0"' &&
  run 'sudo grep -A5 "user_rules:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "csb1"'; then
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
