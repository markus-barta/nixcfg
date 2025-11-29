#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T02: Node-RED Test
# Tests Node-RED container and accessibility
#

set -euo pipefail

HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_USER="${CSB0_USER:-mba}"
SSH_PORT="${CSB0_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"
EXTERNAL_URL="https://home.barta.cm"

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

echo "=== T02: Node-RED Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "External URL: $EXTERNAL_URL"
echo

FAILURES=0

# Test 1: Container running
echo -n "Test 1: Node-RED container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}" | grep -q nodered' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: Container stable
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "{{.RestartCount}}" $(docker ps -q --filter name=nodered) 2>/dev/null' 2>/dev/null | head -1 || echo "999")
if [[ "$RESTARTS" -lt 5 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${RED}❌ FAIL${NC} ($RESTARTS restarts)"
  ((FAILURES++))
fi

# Test 3: Flows data directory
echo -n "Test 3: Flows data exists... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec $(docker ps -q --filter name=nodered) test -f /data/flows.json' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (flows.json not found)"
fi

# Test 4: External URL accessible
echo -n "Test 4: External URL... "
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 "$EXTERNAL_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "401" ]] || [[ "$HTTP_CODE" == "302" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $HTTP_CODE)"
  ((FAILURES++))
fi

# Test 5: SSL certificate
echo -n "Test 5: SSL certificate... "
if curl -s --connect-timeout 10 "$EXTERNAL_URL" 2>&1 | grep -q "SSL certificate verify ok" || curl -sI "$EXTERNAL_URL" &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK SSL${NC}"
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAILURES test(s) failed${NC}"
  exit 1
fi
