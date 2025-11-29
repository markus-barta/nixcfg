#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# 00: Pre-Migration Build Test
# Builds the new configuration WITHOUT applying it
# Run this BEFORE migration to verify the build will succeed
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}" # 10 minutes for build

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== 00: Pre-Migration Build Test ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "This will build the new config WITHOUT applying it."
echo

# Check SSH access first
echo -n "Step 1: Verifying SSH access... "
if ssh -p "$SSH_PORT" -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes "$SSH_USER@$HOST" 'echo ok' &>/dev/null; then
  echo -e "${GREEN}✅ OK${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  echo "Cannot connect to $HOST. Aborting."
  exit 1
fi

# Check if nixcfg repo exists and is up to date
echo -n "Step 2: Checking nixcfg repository... "
REPO_STATUS=$(ssh -p "$SSH_PORT" -o ConnectTimeout="$SSH_TIMEOUT" "$SSH_USER@$HOST" '
  cd ~/Code/nixcfg 2>/dev/null || cd ~/nixcfg 2>/dev/null || { echo "NOT_FOUND"; exit 0; }
  git fetch origin 2>/dev/null
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse origin/main)
  if [ "$LOCAL" = "$REMOTE" ]; then
    echo "UP_TO_DATE"
  else
    echo "BEHIND"
  fi
' 2>/dev/null || echo "ERROR")

case "$REPO_STATUS" in
"UP_TO_DATE")
  echo -e "${GREEN}✅ Up to date${NC}"
  ;;
"BEHIND")
  echo -e "${YELLOW}⚠️ Behind origin${NC}"
  echo "   Run 'git pull' on server before migration!"
  ;;
"NOT_FOUND")
  echo -e "${RED}❌ Repo not found${NC}"
  echo "   Expected at ~/Code/nixcfg or ~/nixcfg"
  exit 1
  ;;
*)
  echo -e "${YELLOW}⚠️ Could not check${NC}"
  ;;
esac

# Check current generation (for comparison)
echo -n "Step 3: Recording current generation... "
CURRENT_GEN=$(ssh -p "$SSH_PORT" -o ConnectTimeout="$SSH_TIMEOUT" "$SSH_USER@$HOST" \
  'readlink /nix/var/nix/profiles/system | sed "s/system-\([0-9]*\)-link/\1/"' 2>/dev/null || echo "unknown")
echo -e "${GREEN}Generation $CURRENT_GEN${NC}"

# Build WITHOUT switching
echo
echo "Step 4: Building new configuration (this may take several minutes)..."
echo "   Command: nixos-rebuild build --flake .#csb1"
echo

BUILD_OUTPUT=$(mktemp)
BUILD_START=$(date +%s)

if ssh -p "$SSH_PORT" -o ConnectTimeout="$SSH_TIMEOUT" -o ServerAliveInterval=30 "$SSH_USER@$HOST" \
  'cd ~/Code/nixcfg 2>/dev/null || cd ~/nixcfg; sudo nixos-rebuild build --flake .#csb1 2>&1' \
  >"$BUILD_OUTPUT" 2>&1; then
  BUILD_END=$(date +%s)
  BUILD_DURATION=$((BUILD_END - BUILD_START))
  echo -e "${GREEN}✅ BUILD SUCCESSFUL${NC} (${BUILD_DURATION}s)"
  BUILD_SUCCESS=true
else
  BUILD_END=$(date +%s)
  BUILD_DURATION=$((BUILD_END - BUILD_START))
  echo -e "${RED}❌ BUILD FAILED${NC} (${BUILD_DURATION}s)"
  BUILD_SUCCESS=false
fi

# Show build output summary
echo
echo "Build output (last 30 lines):"
echo "─────────────────────────────────────────"
tail -30 "$BUILD_OUTPUT"
echo "─────────────────────────────────────────"

# Check what would change
if $BUILD_SUCCESS; then
  echo
  echo "Step 5: Checking what would change..."
  DIFF_OUTPUT=$(ssh -p "$SSH_PORT" -o ConnectTimeout="$SSH_TIMEOUT" "$SSH_USER@$HOST" \
    'sudo nix store diff-closures /run/current-system /nix/var/nix/profiles/system 2>/dev/null | head -50' 2>/dev/null || echo "(diff not available)")

  if [ -n "$DIFF_OUTPUT" ] && [ "$DIFF_OUTPUT" != "(diff not available)" ]; then
    echo "Changes from current system:"
    echo "$DIFF_OUTPUT"
  else
    echo "   (No diff available or no changes)"
  fi
fi

# Cleanup
rm -f "$BUILD_OUTPUT"

# Summary
echo
echo "═══════════════════════════════════════════════════════════"
if $BUILD_SUCCESS; then
  echo -e "  ${GREEN}✅ BUILD TEST PASSED${NC}"
  echo
  echo "  The new configuration builds successfully."
  echo "  Current generation: $CURRENT_GEN"
  echo
  echo "  Ready to migrate:"
  echo "    sudo nixos-rebuild switch --flake .#csb1"
  echo
  echo "  Rollback if needed:"
  echo "    sudo nixos-rebuild switch --rollback"
else
  echo -e "  ${RED}❌ BUILD TEST FAILED${NC}"
  echo
  echo "  Fix the errors above before attempting migration."
  echo "  The build output has been displayed for debugging."
fi
echo "═══════════════════════════════════════════════════════════"

$BUILD_SUCCESS
