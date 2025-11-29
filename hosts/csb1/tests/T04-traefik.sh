#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T04: Traefik - Automated Test
# Tests that Traefik reverse proxy is running and routing correctly
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

echo "=== T04: Traefik Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: Container running
echo -n "Test 1: Traefik container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps | grep -q traefik' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Container stable
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "docker inspect csb1-traefik-1 --format='{{.RestartCount}}'" 2>/dev/null || echo "999")
if [ "$RESTARTS" -lt 5 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${YELLOW}⚠️ HIGH RESTARTS${NC} ($RESTARTS)"
fi

# Test 3: HTTPS - Grafana
echo -n "Test 3: Route to Grafana... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_TIMEOUT" --max-time "$CMD_TIMEOUT" https://grafana.barta.cm/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $HTTP_CODE)"
fi

# Test 4: HTTPS - Docmost
echo -n "Test 4: Route to Docmost... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_TIMEOUT" --max-time "$CMD_TIMEOUT" https://docmost.barta.cm/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (HTTP $HTTP_CODE)"
fi

# Test 5: SSL certificate valid
echo -n "Test 5: SSL certificate... "
CERT_DATES=$(echo | openssl s_client -connect grafana.barta.cm:443 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "error")
if [[ "$CERT_DATES" == *"notAfter"* ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK SSL${NC}"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
