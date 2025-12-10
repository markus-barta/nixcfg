#!/usr/bin/env bash
#
# T10: ZFS Storage - Automated Test
# Tests that ZFS storage is functioning correctly
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
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T10: ZFS Storage Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: ZFS pool exists and is ONLINE
echo -n "Test 1: ZFS pool status... "
if run 'zpool status zroot | grep -q "state: ONLINE"'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: ZFS pool usage
echo -n "Test 2: ZFS pool usage... "
USAGE=$(run 'zpool list zroot -H -o capacity' | tr -d '%')
if [ "$USAGE" -lt 80 ]; then
  echo -e "${GREEN}✅ PASS${NC} (${USAGE}% used)"
else
  echo -e "${YELLOW}⚠️  HIGH USAGE${NC} (${USAGE}%)"
fi

# Test 3: No ZFS errors
echo -n "Test 3: ZFS errors check... "
if run 'zpool status zroot' | grep -q "No known data errors"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (Errors detected)"
  exit 1
fi

# Test 4: Compression enabled (check for zstd or lz4)
echo -n "Test 4: Compression enabled... "
# shellcheck disable=SC2016
COMPRESSION=$(run 'zfs get -H compression zroot | awk "{print \$3}"')
if [ "$COMPRESSION" = "zstd" ] || [ "$COMPRESSION" = "lz4" ] || [ "$COMPRESSION" = "lz4-1" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($COMPRESSION)"
else
  echo -e "${RED}❌ FAIL${NC} (found: $COMPRESSION)"
  exit 1
fi

# Test 5: Filesystems mounted
echo -n "Test 5: Filesystems mounted... "
FS_COUNT=$(run 'zfs list | grep -c zroot' || echo "0")
if [ "$FS_COUNT" -ge 3 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($FS_COUNT filesystems)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
