#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T14: Firewall & Network Test
# Verifies firewall rules and network configuration
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"
PORT_TIMEOUT="${PORT_TIMEOUT:-5}"

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

echo "=== T14: Firewall & Network Test ==="
echo "Host: $HOST ($HOST_IP)"
echo

FAILURES=0
WARNINGS=0

# Function to check if port is open
check_port() {
  local host=$1
  local port=$2
  if nc -z -w "$PORT_TIMEOUT" "$host" "$port" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Test 1: SSH port accessible
echo -n "Test 1: SSH port $SSH_PORT accessible... "
if check_port "$HOST" "$SSH_PORT"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: HTTP port accessible
echo -n "Test 2: HTTP port 80 accessible... "
if check_port "$HOST" 80; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (may redirect to HTTPS)"
  ((WARNINGS++))
fi

# Test 3: HTTPS port accessible
echo -n "Test 3: HTTPS port 443 accessible... "
if check_port "$HOST" 443; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 4: Default SSH port should be CLOSED
echo -n "Test 4: Default SSH port 22 blocked... "
if ! check_port "$HOST" 22; then
  echo -e "${GREEN}✅ PASS${NC} (port 22 blocked - good!)"
else
  echo -e "${YELLOW}⚠️ OPEN${NC} (consider blocking port 22)"
  ((WARNINGS++))
fi

# Test 5: Grafana direct port should be blocked
echo -n "Test 5: Grafana port 3000 blocked... "
if ! check_port "$HOST" 3000; then
  echo -e "${GREEN}✅ PASS${NC} (internal only)"
else
  echo -e "${RED}❌ EXPOSED${NC} (should be behind Traefik!)"
  ((FAILURES++))
fi

# Test 6: PostgreSQL port should be blocked
echo -n "Test 6: PostgreSQL port 5432 blocked... "
if ! check_port "$HOST" 5432; then
  echo -e "${GREEN}✅ PASS${NC} (internal only)"
else
  echo -e "${RED}❌ EXPOSED${NC} (critical security issue!)"
  ((FAILURES++))
fi

# Test 7: Firewall enabled on server
echo -n "Test 7: NixOS firewall enabled... "
FW_STATUS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo iptables -L INPUT -n 2>/dev/null | grep -c "DROP\|REJECT" || echo 0' 2>/dev/null | tr -d '\n\r')
if [ "${FW_STATUS:-0}" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (may be using nftables)"
  ((WARNINGS++))
fi

# Test 8: DNS resolution
echo -n "Test 8: DNS resolution... "
RESOLVED_IP=$(dig +short "$HOST" 2>/dev/null | head -1)
if [ "$RESOLVED_IP" = "$HOST_IP" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($RESOLVED_IP)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (got: $RESOLVED_IP, expected: $HOST_IP)"
  ((WARNINGS++))
fi

# Test 9: Subdomain DNS (Grafana)
echo -n "Test 9: Grafana subdomain DNS... "
GRAFANA_IP=$(dig +short grafana.barta.cm 2>/dev/null | head -1)
if [ -n "$GRAFANA_IP" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($GRAFANA_IP)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC}"
  ((WARNINGS++))
fi

# Test 10: Direct IP access
echo -n "Test 10: Direct IP access... "
if check_port "$HOST_IP" "$SSH_PORT"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Show listening ports from server
echo
echo "Listening ports on server:"
$TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo ss -tlnp 2>/dev/null | grep LISTEN | head -15' 2>/dev/null || echo "  (failed to list)"

echo
echo "========================================"
if [ $FAILURES -gt 0 ]; then
  echo -e "${RED}❌ Firewall/network configuration issues!${NC}"
  echo "   Failures: $FAILURES"
  echo "   Warnings: $WARNINGS"
  echo
  echo "Review firewall rules immediately!"
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo -e "${YELLOW}⚠️ Network configured with warnings${NC}"
  echo "   Failures: $FAILURES"
  echo "   Warnings: $WARNINGS"
  exit 0
else
  echo -e "${GREEN}🎉 Firewall & network properly configured!${NC}"
  exit 0
fi
