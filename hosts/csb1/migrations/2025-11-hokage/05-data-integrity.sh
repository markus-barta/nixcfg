#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T12: Data Integrity Test
# Verifies critical data and databases are intact
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

# Timeout command
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
NC='\033[0m'

echo "=== T12: Data Integrity Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

FAILURES=0

# Test 1: Docker volumes exist
echo -n "Test 1: Docker volumes exist... "
VOLUME_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker volume ls -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "${VOLUME_COUNT:-0}" -gt 5 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($VOLUME_COUNT volumes)"
else
  echo -e "${RED}❌ FAIL${NC} (only $VOLUME_COUNT volumes!)"
  ((FAILURES++))
fi

# Test 2: Grafana data directory
echo -n "Test 2: Grafana data directory... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec csb1-grafana-1 test -d /var/lib/grafana' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 3: InfluxDB data directory
echo -n "Test 3: InfluxDB data directory... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec csb1-influxdb-1 test -d /var/lib/influxdb3' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 4: Paperless database connection
echo -n "Test 4: Paperless database... "
PAPERLESS_DB=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec csb1-paperless-db-1 psql -U paperless -c "SELECT 1;" 2>/dev/null' 2>/dev/null || echo "")
if echo "$PAPERLESS_DB" | grep -q "1"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC}"
fi

# Test 5: Docmost database connection
echo -n "Test 5: Docmost database... "
DOCMOST_DB=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec csb1-docmost-db-1 psql -U docmost -c "SELECT 1;" 2>/dev/null' 2>/dev/null || echo "")
if echo "$DOCMOST_DB" | grep -q "1"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC}"
fi

# Test 6: ZFS docker dataset
echo -n "Test 6: ZFS docker dataset... "
ZFS_DOCKER=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'zfs list 2>/dev/null | grep -c docker || echo 0' 2>/dev/null | tr -d '\n\r')
if [ "${ZFS_DOCKER:-0}" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (docker may use default storage)"
fi

# Test 7: NixOS working
echo -n "Test 7: NixOS operational... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'nixos-version' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 8: Docker data directory exists
echo -n "Test 8: Docker data directory... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'test -d /var/lib/docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 9: Restic backup container exists
echo -n "Test 9: Backup container... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps | grep -q restic' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC}"
fi

# Test 10: Traefik certificates
echo -n "Test 10: Traefik SSL certificates... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec csb1-traefik-1 test -f /letsencrypt/acme.json' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (will regenerate on first request)"
fi

echo
if [ $FAILURES -gt 0 ]; then
  echo -e "${RED}❌ Data integrity issues detected!${NC}"
  echo "   $FAILURES critical failures"
  echo "   Check backup restoration procedures in secrets/RUNBOOK.md"
  exit 1
else
  echo -e "${GREEN}🎉 All data integrity checks passed!${NC}"
  exit 0
fi
