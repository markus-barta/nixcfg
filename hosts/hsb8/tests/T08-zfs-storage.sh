#!/usr/bin/env bash
#
# T08: ZFS Storage - Automated Test
# Tests that ZFS storage is healthy and functioning
#
# shellcheck disable=SC2029

set -euo pipefail

# Configuration
HOST="${HSB8_HOST:-192.168.1.100}"
SSH_USER="${HSB8_USER:-mba}"
POOL_NAME="zroot"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T08: ZFS Storage Test ==="
echo "Host: $HOST"
echo "Pool: $POOL_NAME"
echo

# Test 1: Check if ZFS pool exists
echo -n "Test 1: ZFS pool exists... "
if ssh "$SSH_USER@$HOST" "zpool list $POOL_NAME" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Check pool health
echo -n "Test 2: ZFS pool health... "
HEALTH=$(ssh "$SSH_USER@$HOST" "zpool list -H -o health $POOL_NAME")
if [ "$HEALTH" = "ONLINE" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($HEALTH)"
else
  echo -e "${RED}❌ FAIL${NC} ($HEALTH)"
  exit 1
fi

# Test 3: Check for errors
echo -n "Test 3: ZFS errors check... "
ERRORS=$(ssh "$SSH_USER@$HOST" "zpool status $POOL_NAME | grep -i 'errors:' | awk '{print \$NF}'")
if [ "$ERRORS" = "No" ] || [ "$ERRORS" = "0" ]; then
  echo -e "${GREEN}✅ PASS${NC} (No errors)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (Errors detected: $ERRORS)"
fi

# Test 4: Check compression
echo -n "Test 4: ZFS compression enabled... "
COMPRESSION=$(ssh "$SSH_USER@$HOST" "zfs get -H -o value compression $POOL_NAME")
if [ "$COMPRESSION" != "off" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($COMPRESSION)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (Compression disabled)"
fi

# Test 5: Check pool capacity
echo -n "Test 5: ZFS pool capacity... "
CAPACITY=$(ssh "$SSH_USER@$HOST" "zpool list -H -o capacity $POOL_NAME" | tr -d '%')
if [ "$CAPACITY" -lt 80 ]; then
  echo -e "${GREEN}✅ PASS${NC} (${CAPACITY}% used)"
elif [ "$CAPACITY" -lt 90 ]; then
  echo -e "${YELLOW}⚠️  WARN${NC} (${CAPACITY}% used - consider cleanup)"
else
  echo -e "${RED}❌ FAIL${NC} (${CAPACITY}% used - critical)"
  exit 1
fi

# Test 6: Check filesystems are mounted
echo -n "Test 6: ZFS filesystems mounted... "
FS_COUNT=$(ssh "$SSH_USER@$HOST" "zfs list | wc -l")
if [ "$FS_COUNT" -gt 1 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($((FS_COUNT - 1)) filesystems)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
echo
echo "=== ZFS Pool Summary ==="
ssh "$SSH_USER@$HOST" "zpool list $POOL_NAME"
exit 0
