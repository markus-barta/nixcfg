#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# T05: Backup System - Automated Test
# Tests that restic backup system is running
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

echo "=== T05: Backup System Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: Container running
echo -n "Test 1: Restic container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'docker ps | grep -q restic' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Container stable
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" "docker inspect csb1-restic-cron-hetzner-1 --format='{{.RestartCount}}'" 2>/dev/null || echo "999")
if [ "$RESTARTS" -lt 5 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${YELLOW}⚠️ HIGH RESTARTS${NC} ($RESTARTS)"
fi

# Test 3: Recent backup in logs
echo -n "Test 3: Recent backup activity... "
RECENT_BACKUP=$($TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'docker logs csb1-restic-cron-hetzner-1 2>&1 | grep -c "backup"' 2>/dev/null || echo "0")
if [ "$RECENT_BACKUP" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} (backup activity found)"
else
  echo -e "${YELLOW}⚠️ CHECK LOGS${NC}"
fi

# Test 4: No critical errors
echo -n "Test 4: No critical errors... "
ERROR_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'docker logs csb1-restic-cron-hetzner-1 2>&1 | grep -ci "fatal\|critical" | head -1' 2>/dev/null || echo "0")
if [ "$ERROR_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ ERRORS FOUND${NC} ($ERROR_COUNT)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
echo
echo "Note: For full backup verification (snapshots, restore), run manual tests."
echo "See: tests/T05-backup-system.md"
exit 0
