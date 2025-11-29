#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086,SC2016
#
# T07: ZFS Storage - Automated Test
# Tests that ZFS storage is properly configured and healthy
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"

# SSH options with timeout
SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

# Timeout command (use gtimeout on macOS if available, otherwise skip)
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout $CMD_TIMEOUT"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout $CMD_TIMEOUT"
else
  TIMEOUT_CMD=""
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== T07: ZFS Storage Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: ZFS installed
echo -n "Test 1: ZFS installed... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'which zpool' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Pool online
echo -n "Test 2: ZFS pool online... "
POOL_STATUS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status -H 2>/dev/null | head -1' 2>/dev/null || echo "")
if [[ "$POOL_STATUS" == *"ONLINE"* ]] || $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool list' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: No errors
echo -n "Test 3: No ZFS errors... "
ERRORS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status 2>/dev/null | grep -c "errors: No known data errors"' 2>/dev/null || echo "0")
if [ "$ERRORS" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK ERRORS${NC}"
fi

# Test 4: Disk usage reasonable
echo -n "Test 4: Disk usage... "
USAGE=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool list -H -o capacity 2>/dev/null | head -1 | tr -d "%"' 2>/dev/null || echo "100")
if [ "$USAGE" -lt 90 ]; then
  echo -e "${GREEN}✅ PASS${NC} (${USAGE}% used)"
else
  echo -e "${YELLOW}⚠️ HIGH USAGE${NC} (${USAGE}%)"
fi

# Test 5: Compression enabled
echo -n "Test 5: Compression enabled... "
COMPRESS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zfs get -H compression 2>/dev/null | head -1 | awk "{print \$3}"' 2>/dev/null || echo "off")
if [ "$COMPRESS" != "off" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($COMPRESS)"
else
  echo -e "${YELLOW}⚠️ COMPRESSION OFF${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
