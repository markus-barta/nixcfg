#!/usr/bin/env bash
#
# T04: Docker Services - Automated Test
# Tests that all expected Docker services are running on hsb1
#
# Can run locally on hsb1 OR remotely via SSH
#

set -euo pipefail

# Configuration
TARGET_HOST="hsb1"
HOST="${HSB1_HOST:-192.168.1.101}"
SSH_USER="${HSB1_USER:-mba}"

# Detect if running locally on target host
if [[ "$(hostname)" == "$TARGET_HOST" ]]; then
  run() { eval "$1"; }
  RUN_MODE="local"
else
  # shellcheck disable=SC2029
  run() { ssh "$SSH_USER@$HOST" "$1" 2>/dev/null; }
  RUN_MODE="remote"
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Expected services (must be running). T37 pins this exact set to the
# evaluated hsb1 compose specification so this executable cannot drift behind
# the accompanying Markdown again.
EXPECTED_SERVICES=(
  "apprise"
  "fritz-tripwire"
  "funkeykid"
  "homeassistant"
  "hsb1-home"
  "matter-server"
  "mosquitto"
  "nodered"
  "opus-stream-to-mqtt"
  "opusweb"
  "pharos-beacon"
  "pixdcon"
  "plex"
  "restic-cron-hetzner"
  "scrypted"
  "smtp"
  "turbogmailify"
  "zigbee2mqtt"
)

echo "=== T04: Docker Services Test ==="
echo "Host: $HOST ($RUN_MODE)"
echo

# Test 1: Docker daemon running
echo -n "Test 1: Docker daemon... "
if run 'systemctl is-active docker' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (Docker not running)"
  exit 1
fi

# Test 2: Count running containers
echo -n "Test 2: Running containers... "
RUNNING=$(run 'docker ps --format "{{.Names}}" | wc -l' || echo "0")
echo -e "${GREEN}✅ $RUNNING containers running${NC}"

# Test 3: Check each expected service through the canonical Compose project.
# Raw container names are not equivalent to service keys: smtp intentionally
# has no container_name and is therefore named docker-smtp-1 by Compose.
echo
echo "Test 3: Expected services:"
if ! RUNNING_SERVICES=$(run 'sudo -n docker compose -p docker -f /etc/compose/hsb1/docker-compose.yml --project-directory /home/mba/Code/nixcfg/hosts/hsb1/docker ps --status running --services'); then
  echo -e "${RED}❌ Cannot query the canonical Compose project${NC}"
  exit 1
fi
MISSING=0
for service in "${EXPECTED_SERVICES[@]}"; do
  echo -n "  - $service... "
  if grep -Fxq "$service" <<<"$RUNNING_SERVICES"; then
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
if run 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8123 2>/dev/null | grep -qE "200|302"'; then
  echo -e "${GREEN}✅ Responding${NC}"
else
  echo -e "${YELLOW}⚠️ Not responding${NC}"
fi

echo -n "  - Node-RED (1880)... "
if run 'curl -s -o /dev/null -w "%{http_code}" http://localhost:1880 2>/dev/null | grep -qE "200|302"'; then
  echo -e "${GREEN}✅ Responding${NC}"
else
  echo -e "${YELLOW}⚠️ Not responding${NC}"
fi

echo -n "  - Zigbee2MQTT (8888)... "
if run 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8888 2>/dev/null | grep -qE "200|302"'; then
  echo -e "${GREEN}✅ Responding${NC}"
else
  echo -e "${YELLOW}⚠️ Not responding${NC}"
fi

echo -n "  - MQTT (1883)... "
if run 'ss -tlnp | grep -q ":1883"'; then
  echo -e "${GREEN}✅ Listening${NC}"
else
  echo -e "${YELLOW}⚠️ Not listening${NC}"
fi

# Summary
echo
if [ "$MISSING" -eq 0 ]; then
  echo -e "${GREEN}🎉 All expected services running!${NC}"
  exit 0
else
  echo -e "${RED}⚠️ $MISSING service(s) not running${NC}"
  exit 1
fi
