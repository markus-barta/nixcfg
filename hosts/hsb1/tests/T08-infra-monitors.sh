#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                  T08 - Infrastructure Monitors Automated Tests                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Host: hsb1
# Feature: Netcup Monitor, APC UPS, Nixfleet Agent
#
# Usage: ./T08-infra-monitors.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
TOTAL=0

# ════════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════════════════════

print_header() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

print_test() {
  echo -e "\n${YELLOW}▶ $1${NC}"
  ((TOTAL++)) || true
}

pass() {
  echo -e "${GREEN}  ✅ PASS: $1${NC}"
  ((PASSED++)) || true
}

fail() {
  echo -e "${RED}  ❌ FAIL: $1${NC}"
  ((FAILED++)) || true
}

check_service_active() {
  if systemctl is-active --quiet "$1"; then
    pass "Service $1 is active"
    return 0
  else
    fail "Service $1 is NOT active"
    return 1
  fi
}

check_timer_active() {
  if systemctl is-active --quiet "$1"; then
    pass "Timer $1 is active"
    return 0
  else
    fail "Timer $1 is NOT active"
    return 1
  fi
}

check_file_exists() {
  if [[ -f "$1" ]]; then
    pass "File exists: $1"
    return 0
  else
    fail "File missing: $1"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T08 - Infrastructure Monitors Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T08.1 - Netcup Monitor (Cloud Fleet Health)
# ────────────────────────────────────────────────────────────────────────────────

print_test "T08.1 - Netcup Monitor"
check_timer_active "netcup-monitor.timer"
check_file_exists "/home/mba/bin/netcup-monitor.sh"

# ────────────────────────────────────────────────────────────────────────────────
# T08.2 - APC UPS Monitor
# ────────────────────────────────────────────────────────────────────────────────

print_test "T08.2 - APC UPS Service"
check_service_active "apcupsd.service"
check_timer_active "apc-to-mqtt.timer"
check_file_exists "/home/mba/scripts/apc-to-mqtt.sh"

# ────────────────────────────────────────────────────────────────────────────────
# T08.3 - Nixfleet Agent (Dashboard)
# ────────────────────────────────────────────────────────────────────────────────

print_test "T08.3 - Nixfleet Agent"
check_service_active "nixfleet-agent.service"
check_file_exists "/run/agenix/nixfleet-token"

# ────────────────────────────────────────────────────────────────────────────────
# T08.4 - Networking (Fleet Hosts)
# ────────────────────────────────────────────────────────────────────────────────

print_test "T08.4 - Fleet Connectivity"
# Check if core fleet hosts are resolvable (from /etc/hosts)
for h in hsb0 csb0 csb1 gpc0; do
  if getent hosts "$h" >/dev/null; then
    pass "Host $h is resolvable via /etc/hosts"
  else
    fail "Host $h is NOT resolvable"
  fi
done

# ════════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════════

print_header "Test Summary"

echo ""
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
echo -e "  ${RED}Failed: ${FAILED}${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✅ ALL TESTS PASSED${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
  exit 0
else
  echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
  echo -e "${RED}  ❌ SOME TESTS FAILED${NC}"
  echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
  exit 1
fi
