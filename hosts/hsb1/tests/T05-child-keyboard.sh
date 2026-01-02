#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                  T05 - Child Keyboard Fun Automated Tests                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Host: hsb1
# Feature: child-keyboard-fun service & bluetooth
#
# Usage: ./T05-child-keyboard.sh
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

check_file_exists() {
  if [[ -f "$1" ]]; then
    pass "File exists: $1"
    return 0
  else
    fail "File missing: $1"
    return 1
  fi
}

check_directory_exists() {
  if [[ -d "$1" ]]; then
    pass "Directory exists: $1"
    return 0
  else
    fail "Directory missing: $1"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T05 - Child Keyboard Fun Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T05.1 - Core Service
# ────────────────────────────────────────────────────────────────────────────────

print_test "T05.1 - Systemd Service"
check_service_active "child-keyboard-fun.service"

# ────────────────────────────────────────────────────────────────────────────────
# T05.2 - Python Script & Config
# ────────────────────────────────────────────────────────────────────────────────

print_test "T05.2 - Application Files"
# Note: These paths are from configuration.nix
check_file_exists "/home/mba/Code/nixcfg/hosts/hsb1/files/child-keyboard-fun.py"
check_file_exists "/home/mba/Code/nixcfg/hosts/hsb1/files/child-keyboard-fun.env"

# ────────────────────────────────────────────────────────────────────────────────
# T05.3 - Sound Assets
# ────────────────────────────────────────────────────────────────────────────────

print_test "T05.3 - Sound Assets"
check_directory_exists "/var/lib/child-keyboard-sounds/"

# ────────────────────────────────────────────────────────────────────────────────
# T05.4 - Bluetooth Support
# ────────────────────────────────────────────────────────────────────────────────

print_test "T05.4 - Bluetooth Status"
if bluetoothctl show | grep -q "Powered: yes"; then
  pass "Bluetooth adapter is powered on"
else
  fail "Bluetooth adapter is NOT powered on or not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T05.5 - Input Device Security (Logind)
# ────────────────────────────────────────────────────────────────────────────────

print_test "T05.5 - Power Key Protection"
# check if HandlePowerKey is ignore in /etc/systemd/logind.conf
if grep -q "HandlePowerKey=ignore" /etc/systemd/logind.conf; then
  pass "HandlePowerKey is ignored (safety first!)"
else
  fail "HandlePowerKey is NOT ignored"
fi

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
