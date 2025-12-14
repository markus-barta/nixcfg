#!/usr/bin/env bash
#
# Pre-deploy validation: Check cloud server firewall configs
# Run this BEFORE deploying to catch missing SSH port in firewall
#
# Usage: ./tests/validate-cloud-firewall.sh
#

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Cloud Server Firewall Validation ==="
echo "Checking configuration files for SSH port 2222 in firewall rules"
echo

FAILURES=0

# Cloud servers that need port 2222 in firewall
CLOUD_SERVERS=("csb0" "csb1")

for server in "${CLOUD_SERVERS[@]}"; do
  CONFIG_FILE="$REPO_ROOT/hosts/$server/configuration.nix"

  echo -n "Checking $server... "

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}⚠️ SKIP${NC} (config not found)"
    continue
  fi

  # Check if 2222 is in allowedTCPPorts
  if grep -q 'allowedTCPPorts.*=.*\[' "$CONFIG_FILE"; then
    # Extract the firewall block and check for 2222
    if grep -A10 'firewall\s*=' "$CONFIG_FILE" | grep -q '2222'; then
      echo -e "${GREEN}✅ PASS${NC} (port 2222 in firewall)"
    else
      echo -e "${RED}❌ FAIL${NC} (port 2222 MISSING from allowedTCPPorts!)"
      echo "   ⚠️  This will cause SSH lockout after deploy!"
      echo "   Fix: Add 2222 to networking.firewall.allowedTCPPorts"
      ((FAILURES++))
    fi
  else
    echo -e "${YELLOW}⚠️ WARNING${NC} (no explicit firewall config - relying on hokage)"
    echo "   Consider adding explicit: networking.firewall.allowedTCPPorts = [ 80 443 2222 ];"
  fi
done

echo

# Also check for hashedPassword (recovery access)
echo "=== Recovery Password Check ==="
for server in "${CLOUD_SERVERS[@]}"; do
  CONFIG_FILE="$REPO_ROOT/hosts/$server/configuration.nix"

  echo -n "Checking $server... "

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}⚠️ SKIP${NC}"
    continue
  fi

  if grep -q 'hashedPassword\s*=' "$CONFIG_FILE"; then
    echo -e "${GREEN}✅ PASS${NC} (hashedPassword configured)"
  else
    echo -e "${YELLOW}⚠️ WARNING${NC} (no hashedPassword - VNC recovery won't work)"
  fi
done

echo

if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}🎉 All cloud firewall checks passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAILURES critical issue(s) found - FIX BEFORE DEPLOYING${NC}"
  exit 1
fi
