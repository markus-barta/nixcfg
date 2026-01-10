#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T07: ZFS Storage Test
# Tests ZFS pool health and configuration
#

set -euo pipefail

HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_USER="${CSB0_USER:-mba}"
SSH_PORT="${CSB0_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"

SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout $CMD_TIMEOUT"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout $CMD_TIMEOUT"
else
  TIMEOUT_CMD=""
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T07: ZFS Storage Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

FAILURES=0

# Test 1: ZFS installed
echo -n "Test 1: ZFS installed... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'which zpool' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: ZFS pool online
echo -n "Test 2: ZFS pool online... "
POOL_STATE=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status -x 2>/dev/null | head -1' 2>/dev/null)
if [[ "$POOL_STATE" == "all pools are healthy" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($POOL_STATE)"
  ((FAILURES++))
fi

# Test 3: No ZFS errors
echo -n "Test 3: No ZFS errors... "
ZFS_ERRORS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status 2>/dev/null | grep -c "DEGRADED\|FAULTED\|OFFLINE\|UNAVAIL" || echo 0' 2>/dev/null)
if [[ "$ZFS_ERRORS" -eq 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($ZFS_ERRORS issues found)"
  ((FAILURES++))
fi

# Test 4: Disk usage
echo -n "Test 4: Disk usage... "
USAGE=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool list -H -o capacity 2>/dev/null | head -1 | tr -d "%"' 2>/dev/null || echo "100")
if [[ "$USAGE" -lt 80 ]]; then
  echo -e "${GREEN}✅ PASS${NC} (${USAGE}% used)"
else
  echo -e "${RED}❌ FAIL${NC} (${USAGE}% used)"
  ((FAILURES++))
fi

# Test 5: Compression enabled
echo -n "Test 5: Compression enabled... "
COMPRESSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zfs get compression -H -o value zroot 2>/dev/null' 2>/dev/null || echo "off")
if [[ "$COMPRESSION" != "off" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($COMPRESSION)"
else
  echo -e "${RED}❌ FAIL${NC} (compression off)"
  ((FAILURES++))
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAILURES test(s) failed${NC}"
  exit 1
fi
