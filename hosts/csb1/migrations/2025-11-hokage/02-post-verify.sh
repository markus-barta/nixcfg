#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086,SC2012,SC2016
#
# T09: Post-Migration Verification
# Compares current state against pre-migration snapshot
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

# Find snapshot file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/snapshots"

if [ $# -gt 0 ]; then
  SNAPSHOT_FILE="$1"
else
  # Find most recent pre-migration snapshot
  SNAPSHOT_FILE=$(ls -t "$SNAPSHOT_DIR"/pre-migration-*.json 2>/dev/null | head -1)
fi

if [ -z "$SNAPSHOT_FILE" ] || [ ! -f "$SNAPSHOT_FILE" ]; then
  echo -e "${RED}❌ No snapshot file found!${NC}"
  echo "Run T08 first to create a pre-migration snapshot, or specify a snapshot file."
  echo "Usage: $0 [snapshot-file.json]"
  exit 1
fi

echo "=== T09: Post-Migration Verification ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "Comparing against: $SNAPSHOT_FILE"
echo

FAILURES=0
WARNINGS=0

# Test 1: SSH connectivity
echo -n "Test 1: SSH connectivity... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'echo "ok"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ CRITICAL FAIL${NC}"
  echo "SSH access broken! Cannot continue verification."
  echo "Use VNC console for recovery. See secrets/RUNBOOK.md"
  exit 1
fi

# Test 2: NixOS version
echo -n "Test 2: NixOS version... "
CURRENT_VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null || echo "unknown")
OLD_VERSION=$(grep -oP '"nixos_version": "\K[^"]+' "$SNAPSHOT_FILE" 2>/dev/null || echo "unknown")
if [ "$CURRENT_VERSION" != "unknown" ]; then
  if [ "$CURRENT_VERSION" == "$OLD_VERSION" ]; then
    echo -e "${GREEN}✅ PASS${NC} (same: $CURRENT_VERSION)"
  else
    echo -e "${YELLOW}⚠️ CHANGED${NC} ($OLD_VERSION → $CURRENT_VERSION)"
    ((WARNINGS++))
  fi
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 3: Generation increased
echo -n "Test 3: New generation deployed... "
CURRENT_GEN=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'readlink /nix/var/nix/profiles/system | grep -oP "system-\K[0-9]+"' 2>/dev/null || echo "0")
OLD_GEN=$(grep -oP '"current_generation": "\K[^"]+' "$SNAPSHOT_FILE" 2>/dev/null || echo "0")
if [ "$CURRENT_GEN" -gt "$OLD_GEN" ] 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC} (gen $OLD_GEN → $CURRENT_GEN)"
else
  echo -e "${YELLOW}⚠️ SAME${NC} (still gen $CURRENT_GEN)"
  ((WARNINGS++))
fi

# Test 4: Container count
echo -n "Test 4: Container count... "
CURRENT_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps -q | wc -l' 2>/dev/null | tr -d ' ')
OLD_COUNT=$(grep -c '"name":' "$SNAPSHOT_FILE" 2>/dev/null || echo "0")
if [ "$CURRENT_COUNT" -ge "$OLD_COUNT" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($CURRENT_COUNT containers, was $OLD_COUNT)"
else
  echo -e "${RED}❌ FAIL${NC} ($CURRENT_COUNT < $OLD_COUNT containers!)"
  ((FAILURES++))
fi

# Test 5: No unhealthy containers
echo -n "Test 5: No unhealthy containers... "
UNHEALTHY=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "health=unhealthy" -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "$UNHEALTHY" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} ($UNHEALTHY unhealthy)"
  ((FAILURES++))
fi

# Test 6: Services responding
echo -n "Test 6: Grafana responding... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "https://grafana.barta.cm" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${RED}❌ FAIL${NC} (HTTP $HTTP_CODE)"
  ((FAILURES++))
fi

echo -n "Test 7: Docmost responding... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "https://docmost.barta.cm" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo -e "${GREEN}✅ PASS${NC} (HTTP $HTTP_CODE)"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (HTTP $HTTP_CODE)"
  ((WARNINGS++))
fi

# Test 8: No omega keys (CRITICAL SECURITY)
echo -n "Test 8: No omega keys (security)... "
OMEGA_KEYS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "omega" || echo 0' 2>/dev/null | tr -d '\n\r')
if [ "${OMEGA_KEYS:-0}" -eq 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ SECURITY ISSUE${NC} ($OMEGA_KEYS omega keys found!)"
  echo "⚠️  CRITICAL: External omega keys detected!"
  echo "⚠️  See docs/MIGRATION-PLAN-HOKAGE.md for fix"
  ((FAILURES++))
fi

# Test 9: Passwordless sudo
echo -n "Test 9: Passwordless sudo... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo -n whoami' 2>/dev/null | grep -q "root"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Test 10: ZFS healthy
echo -n "Test 10: ZFS pool healthy... "
ZFS_HEALTH=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status 2>/dev/null | grep -c "ONLINE" || echo 0' 2>/dev/null)
if [ "${ZFS_HEALTH:-0}" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILURES++))
fi

# Summary
echo
echo "========================================"
if [ $FAILURES -gt 0 ]; then
  echo -e "${RED}❌ MIGRATION VERIFICATION FAILED${NC}"
  echo -e "   Failures: $FAILURES"
  echo -e "   Warnings: $WARNINGS"
  echo
  echo -e "${RED}Consider rollback! See T10-rollback-test.md${NC}"
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo -e "${YELLOW}⚠️ MIGRATION COMPLETE WITH WARNINGS${NC}"
  echo -e "   Failures: $FAILURES"
  echo -e "   Warnings: $WARNINGS"
  echo
  echo "Review warnings above before declaring success."
  exit 0
else
  echo -e "${GREEN}🎉 MIGRATION VERIFIED SUCCESSFULLY!${NC}"
  echo -e "   All tests passed"
  echo
  echo "Next steps:"
  echo "  1. Monitor for 24 hours"
  echo "  2. Verify backup runs tonight"
  echo "  3. Run T09 again tomorrow"
  exit 0
fi
