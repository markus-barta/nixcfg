#!/usr/bin/env bash
#
# T04: DHCP Server - Automated Test
# Tests that AdGuard Home DHCP is properly configured
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

echo "=== T04: DHCP Server Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: DHCP enabled (check actual AdGuard config)
echo -n "Test 1: DHCP enabled... "
if run 'sudo grep -A2 "^dhcp:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "enabled: true"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: IP range configured (check actual AdGuard config)
echo -n "Test 2: IP range (201-254)... "
if run 'sudo grep -q "range_start: 192.168.1.201" /var/lib/private/AdGuardHome/AdGuardHome.yaml' &&
  run 'sudo grep -q "range_end: 192.168.1.254" /var/lib/private/AdGuardHome/AdGuardHome.yaml'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Lease duration (24 hours = 86400 seconds)
echo -n "Test 3: Lease duration (24h)... "
if run 'sudo grep "lease_duration:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "86400"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: DHCP port listening
echo -n "Test 4: DHCP port 67... "
if run 'sudo ss -ulpn | grep -q ":67 "'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Gateway configuration (check actual AdGuard config)
echo -n "Test 5: Gateway (192.168.1.5)... "
if run 'sudo grep -q "gateway_ip: 192.168.1.5" /var/lib/private/AdGuardHome/AdGuardHome.yaml'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
