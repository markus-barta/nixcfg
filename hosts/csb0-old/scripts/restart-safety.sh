#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# T16: Pre-Restart Safety Check for csb0
# Verifies everything is ready before a graceful restart
#

set -euo pipefail

# Configuration - csb0
HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_USER="${CSB0_USER:-mba}"
SSH_PORT="${CSB0_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
SERVER_ID="607878"
SERVER_NAME="v2202401214994252795"
API_BASE="https://servercontrolpanel.de/scp-core/api/v1"
AUTH_URL="https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$(dirname "$SCRIPT_DIR")/secrets"
TOKEN_FILE="$SECRETS_DIR/netcup-api-refresh-token.txt"

SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=== T16: Pre-Restart Safety Check (csb0) ==="
echo "Server: $HOST (267+ days uptime)"
echo
echo -e "${YELLOW}⚠️  This checks if restart is SAFE - does NOT restart!${NC}"
echo

READY=true
WARNINGS=0

# Check 1: SSH Access
echo -n "Check 1: SSH access... "
if ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'echo ok' &>/dev/null; then
  echo -e "${GREEN}✅ OK${NC}"
else
  echo -e "${RED}❌ BLOCKED${NC}"
  READY=false
fi

# Check 2: NixOS Generations
echo -n "Check 2: Rollback generations... "
GEN_COUNT=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
if [ "$GEN_COUNT" -ge 2 ]; then
  echo -e "${GREEN}✅ OK${NC} ($GEN_COUNT generations)"
else
  echo -e "${RED}❌ ONLY $GEN_COUNT${NC} (need 2+ for rollback)"
  READY=false
fi

# Check 3: All containers healthy
echo -n "Check 3: Container health... "
UNHEALTHY=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --filter "health=unhealthy" -q | wc -l' 2>/dev/null | tr -d ' ')
if [ "${UNHEALTHY:-0}" -eq 0 ]; then
  echo -e "${GREEN}✅ OK${NC}"
else
  echo -e "${YELLOW}⚠️ $UNHEALTHY unhealthy${NC}"
  ((WARNINGS++))
fi

# Check 4: No restart loops
echo -n "Check 4: No restart loops... "
HIGH_RESTARTS=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker inspect --format "{{.RestartCount}}" $(docker ps -q) 2>/dev/null | awk "\$1 > 10" | wc -l' 2>/dev/null | tr -d ' ')
if [ "${HIGH_RESTARTS:-0}" -eq 0 ]; then
  echo -e "${GREEN}✅ OK${NC}"
else
  echo -e "${YELLOW}⚠️ $HIGH_RESTARTS containers${NC}"
  ((WARNINGS++))
fi

# Check 5: ZFS healthy
echo -n "Check 5: ZFS pool... "
ZFS_STATE=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status -x 2>/dev/null | head -1' 2>/dev/null || echo "unknown")
if [[ "$ZFS_STATE" == *"healthy"* ]] || [[ "$ZFS_STATE" == *"ONLINE"* ]]; then
  echo -e "${GREEN}✅ OK${NC}"
else
  echo -e "${RED}❌ $ZFS_STATE${NC}"
  READY=false
fi

# Check 6: Disk space
echo -n "Check 6: Disk space... "
DISK_USED=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'df / | tail -1 | awk "{print \$5}" | tr -d "%"' 2>/dev/null || echo "100")
if [ "${DISK_USED:-100}" -lt 80 ]; then
  echo -e "${GREEN}✅ OK${NC} (${DISK_USED}% used)"
else
  echo -e "${YELLOW}⚠️ ${DISK_USED}% used${NC}"
  ((WARNINGS++))
fi

# Check 7: Netcup API token
echo -n "Check 7: API token exists... "
if [ -f "$TOKEN_FILE" ]; then
  echo -e "${GREEN}✅ OK${NC}"

  # Check 8: API authentication works
  echo -n "Check 8: API authentication... "
  REFRESH_TOKEN=$(cat "$TOKEN_FILE")
  ACCESS_TOKEN=$(curl -s "$AUTH_URL" \
    -d 'client_id=scp' \
    -d "refresh_token=$REFRESH_TOKEN" \
    -d 'grant_type=refresh_token' 2>/dev/null | jq -r '.access_token // empty')

  if [ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ]; then
    echo -e "${GREEN}✅ OK${NC}"

    # Check 9: Server visible in API
    echo -n "Check 9: Server in API... "
    SERVER_INFO=$(curl -s "$API_BASE/servers/$SERVER_ID" \
      -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null)
    SERVER_STATE=$(echo "$SERVER_INFO" | jq -r '.serverLiveInfo.state // empty')

    if [ "$SERVER_STATE" = "RUNNING" ]; then
      UPTIME_SECS=$(echo "$SERVER_INFO" | jq -r '.serverLiveInfo.uptimeInSeconds // 0')
      UPTIME_DAYS=$((UPTIME_SECS / 86400))
      echo -e "${GREEN}✅ OK${NC} ($SERVER_STATE, $UPTIME_DAYS days)"
    else
      echo -e "${YELLOW}⚠️ State: $SERVER_STATE${NC}"
      ((WARNINGS++))
    fi
  else
    echo -e "${RED}❌ Auth failed${NC}"
    READY=false
  fi
else
  echo -e "${YELLOW}⚠️ Not configured${NC}"
  echo "         Copy from csb1: cp hosts/csb1/secrets/netcup-api-refresh-token.txt $TOKEN_FILE"
  ((WARNINGS++))
fi

# Check 10: VNC access documented
echo -n "Check 10: VNC credentials in RUNBOOK... "
if grep -q "VNC" "$SECRETS_DIR/RUNBOOK.md" 2>/dev/null; then
  echo -e "${GREEN}✅ OK${NC}"
else
  echo -e "${YELLOW}⚠️ Check RUNBOOK${NC}"
  ((WARNINGS++))
fi

# Summary
echo
echo "========================================"
if [ "$READY" = true ] && [ $WARNINGS -eq 0 ]; then
  echo -e "${GREEN}🎉 ALL CHECKS PASSED - Safe to restart${NC}"
  echo
  echo "Recommended restart procedure:"
  echo "1. Have VNC console ready (Netcup SCP)"
  echo "2. Have RUNBOOK.md open"
  echo "3. Use ACPI shutdown (graceful):"
  echo -e "   ${BLUE}curl -X POST '$API_BASE/servers/$SERVER_ID/acpi-shutdown' -H 'Authorization: Bearer \$TOKEN'${NC}"
  echo "4. Wait 60-90 seconds"
  echo "5. Start server:"
  echo -e "   ${BLUE}curl -X POST '$API_BASE/servers/$SERVER_ID/start' -H 'Authorization: Bearer \$TOKEN'${NC}"
  echo "6. Verify with: ssh -p 2222 mba@cs0.barta.cm 'uptime'"
elif [ "$READY" = true ]; then
  echo -e "${YELLOW}⚠️ READY WITH $WARNINGS WARNING(S)${NC}"
  echo "Review warnings above before proceeding."
else
  echo -e "${RED}❌ NOT READY FOR RESTART${NC}"
  echo "Fix issues above before attempting restart."
  exit 1
fi

exit 0
