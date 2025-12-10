#!/usr/bin/env bash
#
# T02: Ad Blocking - Automated Test
# Tests that AdGuard Home ad blocking is enabled
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

echo "=== T02: Ad Blocking Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Protection enabled (check actual AdGuard config)
echo -n "Test 1: Protection enabled... "
if run 'sudo grep -q "protection_enabled: true" /var/lib/private/AdGuardHome/AdGuardHome.yaml'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Filtering enabled (check actual AdGuard config)
echo -n "Test 2: Filtering enabled... "
if run 'sudo grep -q "filtering_enabled: true" /var/lib/private/AdGuardHome/AdGuardHome.yaml'; then
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
