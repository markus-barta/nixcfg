#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T01: Docker Services Test
# Tests Docker and container health
#

set -euo pipefail

# Configuration
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
NC='\033[0m'

echo "=== T01: Docker Services Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

FAILURES=0

# Test 1: Docker service status
echo -n "Test 1: Docker service status... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-active docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: Docker version
echo -n "Test 2: Docker version... "
DOCKER_VER=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker version --format "{{.Server.Version}}"' 2>/dev/null || echo "FAIL")
if [[ "$DOCKER_VER" != "FAIL" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (Docker $DOCKER_VER)"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 3: Running containers
echo -n "Test 3: Running containers... "
CONTAINER_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$CONTAINER_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($CONTAINER_COUNT containers)"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 4: No unhealthy containers
echo -n "Test 4: No unhealthy containers... "
UNHEALTHY=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "health=unhealthy" -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$UNHEALTHY" -eq 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($UNHEALTHY unhealthy)"
  ((FAILURES++))
fi

# Test 5: No restarting containers
echo -n "Test 5: No restarting containers... "
RESTARTING=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "status=restarting" -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$RESTARTING" -eq 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($RESTARTING restarting)"
  ((FAILURES++))
fi

# Test 6: Docker networks
echo -n "Test 6: Docker networks... "
NETWORK_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker network ls -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$NETWORK_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($NETWORK_COUNT networks)"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 7: Docker volumes
echo -n "Test 7: Docker volumes... "
VOLUME_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker volume ls -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$VOLUME_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($VOLUME_COUNT volumes)"
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
