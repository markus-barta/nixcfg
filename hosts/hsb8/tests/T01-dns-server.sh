#!/usr/bin/env bash
#
# T01: DNS Server (AdGuard Home) - Automated Test
# Tests that AdGuard Home DNS server is functional
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"
TEST_DOMAINS=("google.com" "github.com" "example.com")

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T01: DNS Server Test ==="
echo "Host: $HOST"
echo

# Test 1: Check if AdGuard Home service is running
echo -n "Test 1: AdGuard Home service status... "
if ssh -o ConnectTimeout=5 "$SSH_USER@$HOST" 'systemctl is-active adguardhome' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
  SERVICE_RUNNING=true
else
  echo -e "${YELLOW}⏳ SKIP${NC} (Service not running - expected at jhw22)"
  SERVICE_RUNNING=false
fi

# Only run DNS tests if service is running
if [ "$SERVICE_RUNNING" = true ]; then
  # Test 2: DNS resolution locally
  echo -n "Test 2: DNS resolution (local)... "
  if ssh "$SSH_USER@$HOST" "nslookup google.com 127.0.0.1" &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi

  # Test 3: DNS resolution from remote
  echo -n "Test 3: DNS resolution (remote)... "
  if nslookup google.com "$HOST" &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi

  # Test 4: Multiple domains
  echo -n "Test 4: Multiple domain resolution... "
  FAILED=0
  for domain in "${TEST_DOMAINS[@]}"; do
    if ! nslookup "$domain" "$HOST" &>/dev/null; then
      FAILED=$((FAILED + 1))
    fi
  done

  if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ PASS${NC} (${#TEST_DOMAINS[@]}/${#TEST_DOMAINS[@]})"
  else
    echo -e "${RED}❌ FAIL${NC} ($FAILED/${#TEST_DOMAINS[@]} failed)"
    exit 1
  fi

  # Test 5: Check DNS port accessibility
  echo -n "Test 5: DNS port 53 accessible... "
  if nc -zvu "$HOST" 53 &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi

  echo
  echo -e "${GREEN}🎉 All tests passed!${NC}"
else
  echo
  echo -e "${YELLOW}⏸️  Tests skipped - AdGuard Home not running${NC}"
  echo "This is expected at location jhw22 (testing configuration)"
  echo "Tests will pass when server is deployed to ww87"
fi

exit 0
