#!/usr/bin/env bash
#
# T11: ZFS Snapshots - Automated Test
# Tests that ZFS snapshot functionality works
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"
SNAPSHOT_NAME="zroot/root@test-$(date +%Y%m%d-%H%M%S)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=== T11: ZFS Snapshots Test ==="
echo "Host: $HOST"
echo

# Test 1: List snapshots (should not fail)
echo -n "Test 1: List existing snapshots... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'zfs list -t snapshot' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Create a test snapshot
echo -n "Test 2: Create test snapshot... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" "sudo zfs snapshot $SNAPSHOT_NAME" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Verify snapshot exists
echo -n "Test 3: Verify snapshot exists... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" "zfs list -t snapshot | grep -q '$SNAPSHOT_NAME'" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Destroy test snapshot
echo -n "Test 4: Destroy test snapshot... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" "sudo zfs destroy $SNAPSHOT_NAME" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
