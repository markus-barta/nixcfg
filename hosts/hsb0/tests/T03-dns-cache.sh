#!/usr/bin/env bash
#
# T03: DNS Cache - Automated Test
# Tests that DNS caching is properly configured
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

echo "=== T03: DNS Cache Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Cache size configured (check actual AdGuard config)
echo -n "Test 1: Cache size (4MB)... "
if run 'sudo grep -q "cache_size: 4194304" /var/lib/private/AdGuardHome/AdGuardHome.yaml'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Optimistic caching enabled (check actual AdGuard config)
echo -n "Test 2: Optimistic caching... "
if run 'sudo grep -q "cache_optimistic: true" /var/lib/private/AdGuardHome/AdGuardHome.yaml'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Cache performance test (cached query should be fast)
echo -n "Test 3: Cache performance... "
# First query to populate cache
nslookup google.com "$HOST" &>/dev/null
# Second query should be from cache
START=$(date +%s%N)
nslookup google.com "$HOST" &>/dev/null
END=$(date +%s%N)
DURATION=$(((END - START) / 1000000)) # Convert to milliseconds
if [ "$DURATION" -lt 100 ]; then
  echo -e "${GREEN}✅ PASS${NC} (${DURATION}ms)"
else
  echo -e "${RED}⚠️  SLOW${NC} (${DURATION}ms, expected <100ms)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
