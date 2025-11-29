#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# 02: Post-Migration Verification
# Compares current state with pre-migration snapshot
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/snapshots"

# Find latest snapshot
SNAPSHOT_FILE=$(ls -t "$SNAPSHOT_DIR"/pre-migration-*.json 2>/dev/null | head -1)

if [[ -z "$SNAPSHOT_FILE" ]] || [[ ! -f "$SNAPSHOT_FILE" ]]; then
  echo "ERROR: No pre-migration snapshot found in $SNAPSHOT_DIR"
  echo "Run ./01-pre-snapshot.sh first"
  exit 1
fi

echo "=== 02: Post-Migration Verification ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "Comparing against: $SNAPSHOT_FILE"
echo

FAILURES=0
WARNINGS=0

# Load pre-migration values
PRE_VERSION=$(jq -r '.system.nixos_version // "unknown"' "$SNAPSHOT_FILE")
PRE_GENERATION=$(jq -r '.system.generation // 0' "$SNAPSHOT_FILE")
PRE_CONTAINERS=$(jq -r '.docker.container_count // 0' "$SNAPSHOT_FILE")

# Test 1: SSH connectivity
echo -n "Test 1: SSH connectivity... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'echo "ok"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 2: NixOS version
echo -n "Test 2: NixOS version... "
CURRENT_VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null || echo "unknown")
if [[ "$CURRENT_VERSION" != "unknown" ]]; then
  if [[ "$CURRENT_VERSION" != "$PRE_VERSION" ]]; then
    echo -e "${YELLOW}⚠️ CHANGED${NC} ($PRE_VERSION → $CURRENT_VERSION)"
    ((WARNINGS++))
  else
    echo -e "${GREEN}✅ PASS${NC} ($CURRENT_VERSION)"
  fi
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 3: New generation deployed
echo -n "Test 3: New generation deployed... "
CURRENT_GEN=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'readlink /nix/var/nix/profiles/system | grep -oP "system-\K[0-9]+"' 2>/dev/null || echo "0")
if [[ "$CURRENT_GEN" -gt "$PRE_GENERATION" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (gen $PRE_GENERATION → $CURRENT_GEN)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (gen $CURRENT_GEN)"
  ((WARNINGS++))
fi

# Test 4: Container count
echo -n "Test 4: Container count... "
CURRENT_CONTAINERS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$CURRENT_CONTAINERS" -ge "$PRE_CONTAINERS" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($CURRENT_CONTAINERS containers, was $PRE_CONTAINERS)"
else
  echo -e "${RED}❌ FAIL${NC} ($CURRENT_CONTAINERS < $PRE_CONTAINERS)"
  ((FAILURES++))
fi

# Test 5: No unhealthy containers
echo -n "Test 5: No unhealthy containers... "
UNHEALTHY=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "health=unhealthy" -q | wc -l' 2>/dev/null | tr -d ' ')
if [[ "$UNHEALTHY" -eq 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($UNHEALTHY unhealthy)"
  ((FAILURES++))
fi

# Test 6: Node-RED responding
echo -n "Test 6: Node-RED responding... "
NODERED_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 "https://home.barta.cm" 2>/dev/null || echo "000")
if [[ "$NODERED_HTTP" != "000" ]] && [[ "$NODERED_HTTP" != "502" ]] && [[ "$NODERED_HTTP" != "503" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $NODERED_HTTP)"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $NODERED_HTTP)"
  ((FAILURES++))
fi

# Test 7: MQTT broker running (CRITICAL)
echo -n "Test 7: MQTT broker running... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}" | grep -q mosquitto' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (csb1 will lose data!)"
  ((FAILURES++))
fi

# Test 8: No omega keys
echo -n "Test 8: No omega keys (security)... "
OMEGA_KEYS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "omega" || echo 0' 2>/dev/null | tr -d '\n\r')
if [[ "$OMEGA_KEYS" -eq 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ WARNING${NC} ($OMEGA_KEYS omega keys - check lib.mkForce)"
  ((WARNINGS++))
fi

# Test 9: Passwordless sudo
echo -n "Test 9: Passwordless sudo... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo -n whoami' 2>/dev/null | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 10: ZFS pool healthy
echo -n "Test 10: ZFS pool healthy... "
ZFS_HEALTH=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status 2>/dev/null | grep -c "ONLINE" || echo 0' 2>/dev/null)
if [[ "$ZFS_HEALTH" -gt 0 ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

echo
echo "========================================"
if [[ $FAILURES -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
  echo -e "${GREEN}🎉 MIGRATION SUCCESSFUL!${NC}"
elif [[ $FAILURES -eq 0 ]]; then
  echo -e "${YELLOW}⚠️ MIGRATION COMPLETE WITH WARNINGS${NC}"
  echo "   Failures: $FAILURES"
  echo "   Warnings: $WARNINGS"
else
  echo -e "${RED}❌ MIGRATION HAS ISSUES${NC}"
  echo "   Failures: $FAILURES"
  echo "   Warnings: $WARNINGS"
fi
echo
echo "Review warnings above before declaring success."
