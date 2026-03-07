#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T08: Excalidraw - Automated Test
# Tests that Excalidraw whiteboard is running and accessible
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
NC='\033[0m'

echo "=== T08: Excalidraw Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: Container running
echo -n "Test 1: Excalidraw container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps | grep -q excalidraw' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Container stable (low restarts)
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "docker inspect csb1-excalidraw-1 --format='{{.RestartCount}}'" 2>/dev/null || echo "999")
if [ "$RESTARTS" -lt 5 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${RED}❌ FAIL${NC} ($RESTARTS restarts)"
  exit 1
fi

# Test 3: HTTPS reachable
echo -n "Test 3: https://draw.barta.cm reachable... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_TIMEOUT" --max-time "$CMD_TIMEOUT" https://draw.barta.cm/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $HTTP_CODE)"
  exit 1
fi

# Test 4: SSL certificate valid
echo -n "Test 4: SSL certificate valid... "
CERT_DATES=$(echo | openssl s_client -connect draw.barta.cm:443 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "error")
if [[ "$CERT_DATES" == *"notAfter"* ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
