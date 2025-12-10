#!/usr/bin/env bash
#
# T05: Static DHCP Leases - Automated Test
# Tests that static DHCP leases are properly managed via agenix
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

echo "=== T05: Static DHCP Leases Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Agenix secret decrypted
echo -n "Test 1: Agenix secret decrypted... "
if run 'test -f /run/agenix/static-leases-hsb0'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Valid JSON format
echo -n "Test 2: Valid JSON format... "
if run 'jq empty /run/agenix/static-leases-hsb0'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Leases file exists
echo -n "Test 3: Leases file exists... "
if run 'sudo test -f /var/lib/private/AdGuardHome/data/leases.json'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Static leases merged
echo -n "Test 4: Static leases merged... "
STATIC_COUNT=$(run 'sudo cat /var/lib/private/AdGuardHome/data/leases.json | jq "[.leases[] | select(.static == true)] | length"' || echo "0")
if [ "$STATIC_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATIC_COUNT static leases)"
else
  echo -e "${RED}❌ FAIL${NC} (No static leases found)"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
