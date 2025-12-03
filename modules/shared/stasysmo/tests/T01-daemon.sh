#!/usr/bin/env bash
#
# T01: Daemon Running - Automated Test
# Tests that the StaSysMo daemon is running
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== T01: Daemon Running Test ==="
echo

PLATFORM="$(uname)"

if [[ "$PLATFORM" == "Darwin" ]]; then
  # macOS: Check launchd
  echo -n "Test 1: launchd agent loaded... "
  if launchctl list 2>/dev/null | grep -q "stasysmo"; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC} (Agent not loaded)"
    echo "  Hint: Run 'home-manager switch' to install the agent"
    exit 1
  fi

  echo -n "Test 2: Daemon process running... "
  # Check if the launchd job is running (exit code 0 means running)
  if launchctl list com.stasysmo.daemon 2>/dev/null | grep -q "PID"; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    # Might be running but just completed a cycle
    if [[ -f /tmp/stasysmo/timestamp ]]; then
      echo -e "${YELLOW}⚠️ WARN${NC} (No PID but files exist - daemon may be sleeping)"
    else
      echo -e "${RED}❌ FAIL${NC}"
      exit 1
    fi
  fi

  echo -n "Test 3: No errors in log... "
  ERROR_LOG="/tmp/stasysmo-daemon.error.log"
  if [[ -f "$ERROR_LOG" ]]; then
    ERROR_COUNT=$(wc -l <"$ERROR_LOG" | tr -d ' ')
    if [[ "$ERROR_COUNT" -eq 0 ]]; then
      echo -e "${GREEN}✅ PASS${NC} (No errors)"
    else
      echo -e "${YELLOW}⚠️ WARN${NC} ($ERROR_COUNT lines in error log)"
      echo "  Check: cat $ERROR_LOG"
    fi
  else
    echo -e "${GREEN}✅ PASS${NC} (No error log)"
  fi

else
  # Linux: Check systemd
  echo -n "Test 1: systemd service exists... "
  if systemctl list-unit-files 2>/dev/null | grep -q "stasysmo-daemon"; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC} (Service not found)"
    echo "  Hint: Run 'nixos-rebuild switch' to install the service"
    exit 1
  fi

  echo -n "Test 2: Service is active... "
  if systemctl is-active stasysmo-daemon &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    STATUS=$(systemctl is-active stasysmo-daemon 2>/dev/null || echo "unknown")
    echo -e "${RED}❌ FAIL${NC} (Status: $STATUS)"
    exit 1
  fi

  echo -n "Test 3: Service enabled at boot... "
  if systemctl is-enabled stasysmo-daemon &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${YELLOW}⚠️ WARN${NC} (Not enabled at boot)"
  fi
fi

echo
echo -e "${GREEN}🎉 Daemon tests passed!${NC}"
exit 0
