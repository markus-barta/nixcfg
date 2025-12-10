#!/usr/bin/env bash
#
# T11: ZFS Snapshots - Automated Test
# Tests that ZFS snapshot functionality works
#
# Can run locally on hsb0 OR remotely via SSH
#

set -euo pipefail

# Configuration
TARGET_HOST="hsb0"
HOST="${HSB0_HOST:-192.168.1.99}"
SSH_USER="${HSB0_USER:-mba}"
SNAPSHOT_NAME="zroot/root@test-$(date +%Y%m%d-%H%M%S)"

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

echo "=== T11: ZFS Snapshots Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: List snapshots (should not fail)
echo -n "Test 1: List existing snapshots... "
if run 'zfs list -t snapshot' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Create a test snapshot
echo -n "Test 2: Create test snapshot... "
if run "sudo zfs snapshot $SNAPSHOT_NAME"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Verify snapshot exists
echo -n "Test 3: Verify snapshot exists... "
if run "zfs list -t snapshot | grep -q '$SNAPSHOT_NAME'"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Destroy test snapshot
echo -n "Test 4: Destroy test snapshot... "
if run "sudo zfs destroy $SNAPSHOT_NAME"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
