#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T03 - StaSysMo System Metrics - Automated Tests                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests StaSysMo (Starship System Monitoring) daemon and reader functionality
# StaSysMo provides CPU, RAM, Load, and Swap metrics in the Starship prompt
#
# Usage: ./T03-stasysmo.sh
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

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T03 - StaSysMo System Metrics Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T03.1 - StaSysMo Daemon Service
# ────────────────────────────────────────────────────────────────────────────────

print_test "T03.1 - StaSysMo Daemon Service"

if systemctl is-active --quiet stasysmo-daemon 2>/dev/null; then
  pass "stasysmo-daemon service is active"
else
  fail "stasysmo-daemon service is not active"
fi

if systemctl is-enabled --quiet stasysmo-daemon 2>/dev/null; then
  pass "stasysmo-daemon service is enabled"
else
  fail "stasysmo-daemon service is not enabled"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T03.2 - StaSysMo Output Files
# ────────────────────────────────────────────────────────────────────────────────

print_test "T03.2 - StaSysMo Output Files"

SYSMON_DIR="/dev/shm/stasysmo"

if [[ -f "$SYSMON_DIR/cpu" ]]; then
  CPU_VALUE=$(cat "$SYSMON_DIR/cpu")
  pass "cpu file exists: ${CPU_VALUE}%"
else
  fail "cpu file missing in $SYSMON_DIR"
fi

if [[ -f "$SYSMON_DIR/ram" ]]; then
  RAM_VALUE=$(cat "$SYSMON_DIR/ram")
  pass "ram file exists: ${RAM_VALUE}%"
else
  fail "ram file missing in $SYSMON_DIR"
fi

if [[ -f "$SYSMON_DIR/load" ]]; then
  LOAD_VALUE=$(cat "$SYSMON_DIR/load")
  pass "load file exists: $LOAD_VALUE"
else
  fail "load file missing in $SYSMON_DIR"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T03.3 - StaSysMo Reader Command
# ────────────────────────────────────────────────────────────────────────────────

print_test "T03.3 - StaSysMo Reader Command"

if command -v stasysmo-reader &>/dev/null; then
  pass "stasysmo-reader command exists"
else
  fail "stasysmo-reader command not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T03.4 - Starship Integration
# ────────────────────────────────────────────────────────────────────────────────

print_test "T03.4 - Starship Integration"

STARSHIP_CONFIG="$HOME/.config/starship.toml"

if [[ -f "$STARSHIP_CONFIG" ]]; then
  if grep -q "custom.stasysmo" "$STARSHIP_CONFIG" 2>/dev/null; then
    pass "Starship has custom.stasysmo section"
  else
    fail "Starship missing custom.stasysmo section"
  fi

  if grep -q "stasysmo-reader" "$STARSHIP_CONFIG" 2>/dev/null; then
    pass "Starship uses stasysmo-reader command"
  else
    fail "Starship doesn't reference stasysmo-reader"
  fi
else
  fail "Starship config not found"
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
