#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T16 - APC UPS Monitoring + MQTT - Automated Tests               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests APC UPS monitoring (apcupsd) and MQTT publishing service
# Verifies UPS communication and MQTT credentials are available
#
# Usage: ./T16-ups-mqtt.sh
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

print_header "T16 - APC UPS Monitoring + MQTT Tests (hsb0)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T16.1 - apcupsd Service Running
# ────────────────────────────────────────────────────────────────────────────────

print_test "T16.1 - apcupsd Service Running"

if systemctl is-active --quiet apcupsd; then
  STATUS=$(systemctl show apcupsd --property=ActiveState --value)
  pass "apcupsd service is $STATUS"
else
  fail "apcupsd service not running"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T16.2 - apcaccess Returns Data
# ────────────────────────────────────────────────────────────────────────────────

print_test "T16.2 - apcaccess Returns UPS Data"

APCACCESS_OUTPUT=$(apcaccess status 2>&1 || echo "ERROR")

if echo "$APCACCESS_OUTPUT" | grep -q "STATUS"; then
  UPS_STATUS=$(echo "$APCACCESS_OUTPUT" | grep "^STATUS" | cut -d: -f2 | xargs)
  pass "UPS accessible, status: $UPS_STATUS"
else
  fail "apcaccess failed or no UPS connected"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T16.3 - MQTT Credentials File Exists
# ────────────────────────────────────────────────────────────────────────────────

print_test "T16.3 - MQTT Credentials Available"

if sudo test -f /run/agenix/mqtt-hsb0; then
  PERMS=$(sudo stat -c "%a" /run/agenix/mqtt-hsb0)
  pass "MQTT credentials exist (permissions: $PERMS)"
else
  fail "MQTT credentials file not found at /run/agenix/mqtt-hsb0"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T16.4 - ups-mqtt-publish Timer Active
# ────────────────────────────────────────────────────────────────────────────────

print_test "T16.4 - MQTT Publish Timer Active"

if systemctl is-active --quiet ups-mqtt-publish.timer; then
  pass "ups-mqtt-publish timer active"
else
  fail "ups-mqtt-publish timer not active"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T16.5 - ups-mqtt-publish Service Exists
# ────────────────────────────────────────────────────────────────────────────────

print_test "T16.5 - MQTT Publish Service Exists"

if systemctl list-unit-files | grep -q "ups-mqtt-publish.service"; then
  pass "ups-mqtt-publish service exists"
else
  fail "ups-mqtt-publish service not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T16.6 - UPS Battery Charge
# ────────────────────────────────────────────────────────────────────────────────

print_test "T16.6 - UPS Battery Status"

if echo "$APCACCESS_OUTPUT" | grep -q "BCHARGE"; then
  BCHARGE=$(echo "$APCACCESS_OUTPUT" | grep "^BCHARGE" | cut -d: -f2 | xargs)
  pass "Battery charge: $BCHARGE"
else
  fail "Cannot read battery charge"
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
