#!/usr/bin/env bash
#
# T12: ZFS Snapshots - Automated Test
# Tests that ZFS snapshot functionality works
#
# shellcheck disable=SC2029

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"
TEST_SNAPSHOT="zroot@test-$(date +%s)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T12: ZFS Snapshots Test ==="
echo "Host: $HOST"
echo

# Test 1: List snapshots
echo -n "Test 1: Can list snapshots... "
if ssh "$SSH_USER@$HOST" 'zfs list -t snapshot' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Create test snapshot
echo -n "Test 2: Can create snapshot... "
if ssh "$SSH_USER@$HOST" "sudo zfs snapshot '$TEST_SNAPSHOT'" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Verify snapshot exists
echo -n "Test 3: Snapshot exists... "
if ssh "$SSH_USER@$HOST" "zfs list -t snapshot | grep -q '$TEST_SNAPSHOT'" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Destroy test snapshot
echo -n "Test 4: Can destroy snapshot... "
if ssh "$SSH_USER@$HOST" "sudo zfs destroy '$TEST_SNAPSHOT'" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
