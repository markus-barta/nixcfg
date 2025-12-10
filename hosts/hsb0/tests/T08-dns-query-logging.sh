#!/usr/bin/env bash
#
# T08: DNS Query Logging - Automated Test
# Tests that DNS query logging is properly configured
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

echo "=== T08: DNS Query Logging Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Query logging enabled (check actual AdGuard config)
echo -n "Test 1: Query logging enabled... "
if run 'sudo grep -A10 "^querylog:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "enabled: true"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: 90-day retention configured (check actual AdGuard config)
echo -n "Test 2: 90-day retention (2160h)... "
if run 'sudo grep -A10 "^querylog:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "interval: 2160h"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Memory size configured (check actual AdGuard config)
echo -n "Test 3: Memory size (1000)... "
if run 'sudo grep -A10 "^querylog:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "size_memory: 1000"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
