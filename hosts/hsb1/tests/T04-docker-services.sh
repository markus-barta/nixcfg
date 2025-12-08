#!/usr/bin/env bash
#
# T04: Docker Services - Automated Test
# Tests that all expected Docker containers are running on hsb1
#

set -euo pipefail

# Configuration
HOST="${HSB1_HOST:-192.168.1.101}"
SSH_USER="${HSB1_USER:-mba}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Expected containers (must be running)
EXPECTED_CONTAINERS=(
  "homeassistant"
  "nodered"
  "mosquitto"
  "zigbee2mqtt"
  "scrypted"
  "matter-server"
  "pidicon"
  "apprise"
  "opus-stream-to-mqtt"
  "smtp"
  "restic-cron-hetzner"
  "watchtower-weekly"
  "watchtower-pidicon"
)

echo "=== T04: Docker Services Test ==="
echo "Host: $HOST"
echo

# Test 1: Docker daemon running
echo -n "Test 1: Docker daemon... "
if ssh "$SSH_USER@$HOST" 'systemctl is-active docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (Docker not running)"
  exit 1
fi

# Test 2: Count running containers
echo -n "Test 2: Running containers... "
RUNNING=$(ssh "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}" | wc -l' 2>/dev/null || echo "0")
echo -e "${GREEN}✅ $RUNNING containers running${NC}"

# Test 3: Check each expected container
echo
echo "Test 3: Expected containers:"
MISSING=0
for container in "${EXPECTED_CONTAINERS[@]}"; do
  echo -n "  - $container... "
  # shellcheck disable=SC2029 # We want $container to expand locally
  if ssh "$SSH_USER@$HOST" "docker ps --format '{{.Names}}' | grep -q '^${container}$'" 2>/dev/null; then
    echo -e "${GREEN}✅ Running${NC}"
  else
    echo -e "${RED}❌ Not running${NC}"
    ((MISSING++)) || true
  fi
done

# Test 4: Key service ports responding
echo
echo "Test 4: Service endpoints:"

echo -n "  - Home Assistant (8123)... "
if ssh "$SSH_USER@$HOST" 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8123 2>/dev/null | grep -qE "200|302"'; then
  echo -e "${GREEN}✅ Responding${NC}"
else
  echo -e "${YELLOW}⚠️ Not responding${NC}"
fi

echo -n "  - Node-RED (1880)... "
if ssh "$SSH_USER@$HOST" 'curl -s -o /dev/null -w "%{http_code}" http://localhost:1880 2>/dev/null | grep -qE "200|302"'; then
  echo -e "${GREEN}✅ Responding${NC}"
else
  echo -e "${YELLOW}⚠️ Not responding${NC}"
fi

echo -n "  - Zigbee2MQTT (8888)... "
if ssh "$SSH_USER@$HOST" 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8888 2>/dev/null | grep -qE "200|302"'; then
  echo -e "${GREEN}✅ Responding${NC}"
else
  echo -e "${YELLOW}⚠️ Not responding${NC}"
fi

echo -n "  - MQTT (1883)... "
if ssh "$SSH_USER@$HOST" 'ss -tlnp | grep -q ":1883"' 2>/dev/null; then
  echo -e "${GREEN}✅ Listening${NC}"
else
  echo -e "${YELLOW}⚠️ Not listening${NC}"
fi

# Summary
echo
if [ "$MISSING" -eq 0 ]; then
  echo -e "${GREEN}🎉 All expected containers running!${NC}"
  exit 0
else
  echo -e "${RED}⚠️ $MISSING container(s) not running${NC}"
  exit 1
fi
