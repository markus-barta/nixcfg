#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086,SC2016
#
# T13: Service Recovery Test (Safe Mode)
# Verifies restart policies without actually restarting
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
BLUE='\033[0;34m'
NC='\033[0m'

echo "=== T13: Service Recovery Test (Safe Mode) ==="
echo "Host: $HOST (port $SSH_PORT)"
echo -e "${BLUE}Note: This test checks configuration only - no actual restart${NC}"
echo

FAILURES=0
WARNINGS=0

# Test 1: Docker service enabled
echo -n "Test 1: Docker systemd service enabled... "
DOCKER_ENABLED=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-enabled docker 2>/dev/null' 2>/dev/null || echo "unknown")
if [ "$DOCKER_ENABLED" = "enabled" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($DOCKER_ENABLED)"
  ((FAILURES++))
fi

# Test 2: Docker service running
echo -n "Test 2: Docker service running... "
DOCKER_ACTIVE=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-active docker 2>/dev/null' 2>/dev/null || echo "unknown")
if [ "$DOCKER_ACTIVE" = "active" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($DOCKER_ACTIVE)"
  ((FAILURES++))
fi

# Test 3: Container restart policies
echo -n "Test 3: Container restart policies... "
POLICIES=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "{{.HostConfig.RestartPolicy.Name}}" $(docker ps -q) 2>/dev/null' 2>/dev/null || echo "")
NO_POLICY=$(echo "$POLICIES" | grep -c "^no$" || echo "0")
TOTAL_CONTAINERS=$(echo "$POLICIES" | grep -c "." || echo "0")
if [ "${NO_POLICY:-0}" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} (all $TOTAL_CONTAINERS containers have restart policy)"
else
  echo -e "${YELLOW}⚠️ WARNING${NC} ($NO_POLICY containers without restart policy)"
  ((WARNINGS++))
fi

# Test 4: SSH service enabled
echo -n "Test 4: SSH service enabled... "
SSH_ENABLED=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-enabled sshd 2>/dev/null' 2>/dev/null || echo "unknown")
if [ "$SSH_ENABLED" = "enabled" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($SSH_ENABLED)"
  ((FAILURES++))
fi

# Test 5: ZFS services enabled
echo -n "Test 5: ZFS import service... "
ZFS_IMPORT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl is-enabled zfs-import-cache.service 2>/dev/null || systemctl is-enabled zfs-import.target 2>/dev/null' 2>/dev/null || echo "unknown")
if [[ "$ZFS_IMPORT" == *"enabled"* ]] || [[ "$ZFS_IMPORT" == *"static"* ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} ($ZFS_IMPORT)"
  ((WARNINGS++))
fi

# Test 6: No containers in restart loop
echo -n "Test 6: No restart loops... "
RESTART_COUNTS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "{{.RestartCount}}" $(docker ps -q) 2>/dev/null' 2>/dev/null || echo "")
HIGH_RESTARTS=$(echo "$RESTART_COUNTS" | awk '$1 > 10' | wc -l | tr -d ' ')
if [ "${HIGH_RESTARTS:-0}" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ WARNING${NC} ($HIGH_RESTARTS containers with high restart counts)"
  ((WARNINGS++))
fi

# Test 7: System uptime (long uptime = stable)
echo -n "Test 7: System stability... "
UPTIME_DAYS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'awk "{print int(\$1/86400)}" /proc/uptime' 2>/dev/null || echo "0")
if [ "${UPTIME_DAYS:-0}" -gt 7 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($UPTIME_DAYS days uptime - stable)"
elif [ "${UPTIME_DAYS:-0}" -gt 0 ]; then
  echo -e "${YELLOW}⚠️ RECENT REBOOT${NC} ($UPTIME_DAYS days)"
  ((WARNINGS++))
else
  echo -e "${YELLOW}⚠️ CHECK${NC}"
  ((WARNINGS++))
fi

# Test 8: Multi-user target enabled
echo -n "Test 8: Multi-user target... "
MULTI_USER=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'systemctl get-default 2>/dev/null' 2>/dev/null || echo "unknown")
if [[ "$MULTI_USER" == *"multi-user"* ]] || [[ "$MULTI_USER" == *"graphical"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($MULTI_USER)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} ($MULTI_USER)"
  ((WARNINGS++))
fi

# List container restart policies
echo
echo "Container restart policies:"
$TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "  {{.Name}}: {{.HostConfig.RestartPolicy.Name}}" $(docker ps -q) 2>/dev/null | head -10' 2>/dev/null || echo "  (failed to list)"

echo
echo "========================================"
if [ $FAILURES -gt 0 ]; then
  echo -e "${RED}❌ Service recovery configuration issues!${NC}"
  echo "   Failures: $FAILURES"
  echo "   Warnings: $WARNINGS"
  echo
  echo "Services may not auto-recover after reboot!"
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo -e "${YELLOW}⚠️ Service recovery configured with warnings${NC}"
  echo "   Failures: $FAILURES"
  echo "   Warnings: $WARNINGS"
  exit 0
else
  echo -e "${GREEN}🎉 Service recovery properly configured!${NC}"
  echo
  echo "All services should auto-start after reboot."
  echo
  echo -e "${BLUE}To perform actual restart test (causes downtime):${NC}"
  echo "  ssh -p 2222 mba@cs1.barta.cm 'sudo reboot'"
  exit 0
fi
