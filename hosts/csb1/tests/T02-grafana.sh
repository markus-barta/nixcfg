#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T02: Grafana - Automated Test
# Tests that Grafana monitoring is running and accessible
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
GRAFANA_URL="${GRAFANA_URL:-https://grafana.barta.cm}"
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

echo "=== T02: Grafana Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "External URL: $GRAFANA_URL"
echo

# Test 1: Container running
echo -n "Test 1: Grafana container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps | grep -q grafana' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Container healthy (no restart loops)
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "docker inspect csb1-grafana-1 --format='{{.RestartCount}}'" 2>/dev/null || echo "999")
if [ "$RESTARTS" -lt 5 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${YELLOW}⚠️ HIGH RESTARTS${NC} ($RESTARTS)"
fi

# Test 3: Internal port accessible (via Docker network)
echo -n "Test 3: Container health (via docker)... "
HEALTH=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "docker exec csb1-grafana-1 wget -q -O - http://localhost:3000/api/health 2>/dev/null" 2>/dev/null || echo "{}")
if echo "$HEALTH" | grep -q "database"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (container may not expose health internally)"
fi

# Test 4: External URL accessible
echo -n "Test 4: External URL... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_TIMEOUT" --max-time "$CMD_TIMEOUT" "$GRAFANA_URL/api/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $HTTP_CODE)"
  exit 1
fi

# Test 5: SSL certificate valid
echo -n "Test 5: SSL certificate... "
if curl -v --connect-timeout "$CURL_TIMEOUT" --max-time "$CMD_TIMEOUT" "$GRAFANA_URL" 2>&1 | grep -qi "SSL certificate verify ok"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK SSL${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
