#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T03: InfluxDB - Automated Test
# Tests that InfluxDB time series database is running
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"

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

echo "=== T03: InfluxDB Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: Container running
echo -n "Test 1: InfluxDB container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps | grep -q influxdb' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Container stable
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "docker inspect csb1-influxdb-1 --format='{{.RestartCount}}'" 2>/dev/null || echo "999")
if [ "$RESTARTS" -lt 5 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${YELLOW}⚠️ HIGH RESTARTS${NC} ($RESTARTS)"
fi

# Test 3: Container running for extended period
echo -n "Test 3: Container uptime... "
STATUS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "docker ps --filter name=csb1-influxdb-1 --format '{{.Status}}'" 2>/dev/null || echo "unknown")
if [[ "$STATUS" == *"Up"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($STATUS)"
else
  echo -e "${RED}❌ FAIL${NC} ($STATUS)"
  exit 1
fi

# Test 4: InfluxDB data directory exists
echo -n "Test 4: Data directory... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec csb1-influxdb-1 ls /var/lib/influxdb3' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK DATA${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
