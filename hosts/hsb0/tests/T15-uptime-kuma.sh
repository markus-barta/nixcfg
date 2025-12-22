#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T15 - Uptime Kuma Service Monitoring - Automated Tests          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests Uptime Kuma service monitoring web interface
# Verifies service is running and web UI is accessible
#
# Usage: ./T15-uptime-kuma.sh
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

print_header "T15 - Uptime Kuma Service Monitoring Tests (hsb0)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T15.1 - Service Running
# ────────────────────────────────────────────────────────────────────────────────

print_test "T15.1 - Uptime Kuma Service Running"

if systemctl is-active --quiet uptime-kuma; then
  STATUS=$(systemctl show uptime-kuma --property=ActiveState --value)
  pass "Uptime Kuma service is $STATUS"
else
  fail "Uptime Kuma service not running"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T15.2 - Port Listening
# ────────────────────────────────────────────────────────────────────────────────

print_test "T15.2 - Port 3001 Listening"

if ss -tlnp | grep -q ':3001'; then
  pass "Port 3001 is listening"
else
  fail "Port 3001 not listening"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T15.3 - Web Interface Accessible
# ────────────────────────────────────────────────────────────────────────────────

print_test "T15.3 - Web Interface Accessible"

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3001 2>/dev/null || echo "000")

if [[ "$RESPONSE" == "200" ]] || [[ "$RESPONSE" == "302" ]]; then
  pass "Web UI responds (HTTP $RESPONSE)"
else
  fail "Web UI not accessible (HTTP $RESPONSE)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T15.4 - Web Page Contains Uptime Kuma
# ────────────────────────────────────────────────────────────────────────────────

print_test "T15.4 - Web Page Content"

PAGE_CONTENT=$(curl -sL http://localhost:3001 2>/dev/null || echo "")

if echo "$PAGE_CONTENT" | grep -qi "uptime"; then
  pass "Page contains Uptime Kuma content"
else
  fail "Page missing Uptime Kuma content"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T15.5 - Apprise Integration (Required for Notifications)
# ────────────────────────────────────────────────────────────────────────────────

print_test "T15.5 - Apprise CLI Availability"

# Check if apprise is in the system path
if command -v apprise >/dev/null 2>&1; then
  APPRISE_VER=$(apprise --version | head -n 1)
  pass "Apprise CLI is available ($APPRISE_VER)"
else
  fail "Apprise CLI not found in system PATH"
fi

# Check if apprise is in the uptime-kuma service path
print_test "T15.6 - Apprise in Uptime Kuma Service PATH"
KUMA_ENV=$(systemctl show uptime-kuma --property=Environment --value)
if echo "$KUMA_ENV" | grep -q "apprise"; then
  pass "Apprise found in Uptime Kuma Environment PATH"
else
  # Fallback check
  if systemctl show uptime-kuma | grep -q "Environment=.*apprise"; then
    pass "Apprise found in Uptime Kuma Environment (fallback check)"
  else
    fail "Apprise not found in Uptime Kuma service environment"
  fi
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
