#!/usr/bin/env bash
#
# T04: DHCP Server - Automated Test
# Tests that AdGuard Home DHCP is properly configured
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T04: DHCP Server Test ==="
echo "Host: $HOST"
echo

# Test 1: DHCP enabled (check actual AdGuard config)
echo -n "Test 1: DHCP enabled... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -A2 "^dhcp:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "enabled: true"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: IP range configured (check actual AdGuard config)
echo -n "Test 2: IP range (201-254)... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -q "range_start: 192.168.1.201" /var/lib/private/AdGuardHome/AdGuardHome.yaml' &&
  ssh "$SSH_USER@$HOST" 'sudo grep -q "range_end: 192.168.1.254" /var/lib/private/AdGuardHome/AdGuardHome.yaml' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Lease duration (24 hours = 86400 seconds)
echo -n "Test 3: Lease duration (24h)... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep "lease_duration:" /var/lib/private/AdGuardHome/AdGuardHome.yaml | grep -q "86400"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: DHCP port listening
echo -n "Test 4: DHCP port 67... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo ss -ulpn | grep -q ":67 "' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Gateway configuration (check actual AdGuard config)
echo -n "Test 5: Gateway (192.168.1.5)... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'sudo grep -q "gateway_ip: 192.168.1.5" /var/lib/private/AdGuardHome/AdGuardHome.yaml' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
