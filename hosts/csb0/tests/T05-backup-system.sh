#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T05: Backup System Test
# Tests restic backup (CRITICAL - manages BOTH servers!)
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
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T05: Backup System Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo -e "${YELLOW}⚠️ CRITICAL: This manages backups for BOTH csb0 AND csb1!${NC}"
echo

FAILURES=0

# Test 1: Restic container running
echo -n "Test 1: Restic container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}" | grep -q restic' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: Container stable
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "{{.RestartCount}}" $(docker ps -q --filter name=restic) 2>/dev/null' 2>/dev/null | head -1 || echo "999")
if [[ "$RESTARTS" -lt 5 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${RED}❌ FAIL${NC} ($RESTARTS restarts)"
  ((FAILURES++))
fi

# Test 3: Recent backup activity
echo -n "Test 3: Recent backup activity... "
LAST_LOG=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker logs $(docker ps -q --filter name=restic) 2>&1 | tail -20 | grep -i "backup\|snapshot" | tail -1' 2>/dev/null || echo "")
if [[ -n "$LAST_LOG" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (backup activity found)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (no recent backup in logs)"
fi

# Test 4: No critical errors
echo -n "Test 4: No critical errors... "
ERRORS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker logs $(docker ps -q --filter name=restic) 2>&1 | tail -50 | grep -ic "error\|fatal" || echo 0' 2>/dev/null | tr -d '\n\r' | head -1)
ERRORS=${ERRORS:-0}
if [[ "$ERRORS" -lt 3 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($ERRORS errors in recent logs)"
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

echo
echo "Note: For full backup verification (snapshots, restore), run manual tests."
echo "See: tests/T05-backup-system.md"
