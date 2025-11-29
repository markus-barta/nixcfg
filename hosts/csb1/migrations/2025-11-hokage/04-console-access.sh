#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# T11: Console Access Verification
# Verifies emergency access methods are available
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$(dirname "$SCRIPT_DIR")/secrets"

echo "=== T11: Console Access Verification ==="
echo "Host: $HOST (port $SSH_PORT)"
echo

# Test 1: SSH key authentication
echo -n "Test 1: SSH key authentication... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" -o PasswordAuthentication=no "$SSH_USER@$HOST" 'echo "ok"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
fi

# Test 2: RUNBOOK.md exists
echo -n "Test 2: RUNBOOK.md exists... "
if [ -f "$SECRETS_DIR/RUNBOOK.md" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (create secrets/RUNBOOK.md!)"
fi

# Test 3: Password documented in RUNBOOK
echo -n "Test 3: User password documented... "
if grep -q "Password" "$SECRETS_DIR/RUNBOOK.md" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (verify password in RUNBOOK.md)"
fi

# Test 4: Netcup info documented
echo -n "Test 4: Netcup credentials documented... "
if grep -qi "netcup\|227044\|servercontrolpanel" "$SECRETS_DIR/RUNBOOK.md" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (add Netcup info to RUNBOOK.md)"
fi

# Test 5: VNC console info documented
echo -n "Test 5: VNC console documented... "
if grep -qi "vnc\|console" "$SECRETS_DIR/RUNBOOK.md" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (add VNC console info)"
fi

# Test 6: Recovery procedure documented
echo -n "Test 6: Recovery procedure documented... "
if grep -qi "recovery\|emergency\|rollback" "$SECRETS_DIR/RUNBOOK.md" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (add recovery procedures)"
fi

# Test 7: IPv4 direct access works
echo -n "Test 7: Direct IP access... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@152.53.64.166" 'echo "ok"' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ CHECK${NC} (direct IP: 152.53.64.166)"
fi

# Test 8: Sudo works (for emergency commands)
echo -n "Test 8: Sudo access... "
if $TIMEOUT_CMD ssh -p "$SSH_PORT" "$SSH_OPTS" "$SSH_USER@$HOST" 'sudo -n true' &>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
fi

echo
echo "========================================"
echo -e "${GREEN}Console access verification complete${NC}"
echo
echo -e "${BLUE}📋 Pre-Migration Checklist:${NC}"
echo "   □ Test VNC console manually (Netcup SCP)"
echo "   □ Verify 2FA device is ready"
echo "   □ Have RUNBOOK.md open during migration"
echo "   □ Know rollback command: sudo nixos-rebuild switch --rollback"
echo
echo -e "${YELLOW}Netcup Console:${NC} https://www.servercontrolpanel.de/SCP"

exit 0
