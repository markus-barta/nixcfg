#!/usr/bin/env bash
#
# T18: Local /etc/hosts - Automated Test
# Tests that local hosts file contains privacy-focused hostnames
#

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T18: Local /etc/hosts Test ==="
echo "Host: $HOST"
echo

# Test 1: /etc/hosts contains hsb8
echo -n "Test 1: /etc/hosts contains hsb8... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "hsb8" /etc/hosts' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: hsb8 resolves to 192.168.1.100
echo -n "Test 2: hsb8 resolves correctly... "
# shellcheck disable=SC2029
RESOLVED_IP=$(ssh "$SSH_USER@$HOST" 'getent hosts hsb8 | awk "{print \$1}"' 2>/dev/null || echo "FAILED")
if [ "$RESOLVED_IP" = "192.168.1.100" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (got: '$RESOLVED_IP')"
  exit 1
fi

# Test 3: hsb8.lan also resolves
echo -n "Test 3: hsb8.lan resolves... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'getent hosts hsb8.lan' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Configuration has networking.hosts
echo -n "Test 4: networking.hosts in config... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'grep -q "networking.hosts" ~/nixcfg/hosts/hsb8/configuration.nix' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 5: Self-resolution works (ping self)
echo -n "Test 5: Self-resolution (ping hsb8)... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'ping -c 1 hsb8' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
