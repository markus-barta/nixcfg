#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T03: MQTT/Mosquitto Test
# Tests MQTT broker (CRITICAL - csb1 depends on this!)
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

echo "=== T03: MQTT/Mosquitto Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo -e "${YELLOW}⚠️ CRITICAL: csb1 depends on this broker!${NC}"
echo

FAILURES=0

# Test 1: Container running
echo -n "Test 1: Mosquitto container running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}" | grep -q mosquitto' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: Container stable
echo -n "Test 2: Container stable... "
RESTARTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "{{.RestartCount}}" $(docker ps -q --filter name=mosquitto) 2>/dev/null' 2>/dev/null | head -1 || echo "999")
if [[ "$RESTARTS" -lt 5 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESTARTS restarts)"
else
  echo -e "${RED}❌ FAIL${NC} ($RESTARTS restarts)"
  ((FAILURES++))
fi

# Test 3: Config file exists
echo -n "Test 3: Config file exists... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec $(docker ps -q --filter name=mosquitto) test -f /mosquitto/config/mosquitto.conf' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 4: MQTT port listening (inside container)
echo -n "Test 4: MQTT port 1883 listening... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker exec $(docker ps -q --filter name=mosquitto) sh -c "netstat -tln 2>/dev/null || ss -tln" | grep -q ":1883"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC}"
fi

# Test 5: Container uptime
echo -n "Test 5: Container uptime... "
UPTIME=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Status}}" --filter name=mosquitto' 2>/dev/null | head -1)
if [[ -n "$UPTIME" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($UPTIME)"
else
  echo -e "${RED}❌ FAIL${NC}"
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
