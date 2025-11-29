#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T01: Docker Services - Automated Test
# Tests that Docker is running and containers are healthy
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
MIN_CONTAINERS="${CSB1_MIN_CONTAINERS:-10}"
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

echo "=== T01: Docker Services Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: Docker service running
echo -n "Test 1: Docker service status... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-active docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Docker version
echo -n "Test 2: Docker version... "
DOCKER_VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker --version' 2>/dev/null || echo "unknown")
if [[ "$DOCKER_VERSION" == Docker* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($DOCKER_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: Container count
echo -n "Test 3: Running containers... "
CONTAINER_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "$CONTAINER_COUNT" -ge "$MIN_CONTAINERS" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($CONTAINER_COUNT containers)"
else
  echo -e "${YELLOW}⚠️ LOW${NC} ($CONTAINER_COUNT containers, expected >=$MIN_CONTAINERS)"
fi

# Test 4: No unhealthy containers
echo -n "Test 4: No unhealthy containers... "
UNHEALTHY=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "health=unhealthy" -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "$UNHEALTHY" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($UNHEALTHY unhealthy)"
  exit 1
fi

# Test 5: No restarting containers
echo -n "Test 5: No restarting containers... "
RESTARTING=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "status=restarting" -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "$RESTARTING" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($RESTARTING restarting)"
  exit 1
fi

# Test 6: Docker networks exist
echo -n "Test 6: Docker networks... "
NETWORK_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker network ls -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "$NETWORK_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($NETWORK_COUNT networks)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 7: Docker volumes exist
echo -n "Test 7: Docker volumes... "
VOLUME_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker volume ls -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "$VOLUME_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($VOLUME_COUNT volumes)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
