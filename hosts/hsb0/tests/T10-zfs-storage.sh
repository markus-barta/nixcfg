#!/usr/bin/env bash
#
# T10: ZFS Storage - Automated Test
# Tests that ZFS storage is functioning correctly
#

set -euo pipefail

# Configuration
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T10: ZFS Storage Test ==="
echo "Host: $HOST"
echo

# Test 1: ZFS pool exists and is ONLINE
echo -n "Test 1: ZFS pool status... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'zpool status zroot | grep -q "state: ONLINE"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: ZFS pool usage
echo -n "Test 2: ZFS pool usage... "
# shellcheck disable=SC2029
USAGE=$(ssh "$SSH_USER@$HOST" 'zpool list zroot -H -o capacity' 2>/dev/null | tr -d '%')
if [ "$USAGE" -lt 80 ]; then
  echo -e "${GREEN}✅ PASS${NC} (${USAGE}% used)"
else
  echo -e "${YELLOW}⚠️  HIGH USAGE${NC} (${USAGE}%)"
fi

# Test 3: No ZFS errors
echo -n "Test 3: ZFS errors check... "
# shellcheck disable=SC2029
if ssh "$SSH_USER@$HOST" 'zpool status zroot' 2>/dev/null | grep -q "No known data errors"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (Errors detected)"
  exit 1
fi

# Test 4: Compression enabled (check for zstd or lz4)
echo -n "Test 4: Compression enabled... "
# shellcheck disable=SC2029
COMPRESSION=$(ssh "$SSH_USER@$HOST" 'zfs get -H compression zroot | awk "{print \$3}"' 2>/dev/null)
if [ "$COMPRESSION" = "zstd" ] || [ "$COMPRESSION" = "lz4" ] || [ "$COMPRESSION" = "lz4-1" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($COMPRESSION)"
else
  echo -e "${RED}❌ FAIL${NC} (found: $COMPRESSION)"
  exit 1
fi

# Test 5: Filesystems mounted
echo -n "Test 5: Filesystems mounted... "
# shellcheck disable=SC2029
FS_COUNT=$(ssh "$SSH_USER@$HOST" 'zfs list | grep -c zroot' 2>/dev/null || echo "0")
if [ "$FS_COUNT" -ge 3 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($FS_COUNT filesystems)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
