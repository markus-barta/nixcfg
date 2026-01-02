#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                  T07 - Kiosk & Media Services Automated Tests                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Host: hsb1
# Feature: X11, Openbox, Kiosk User, VLC Volume Control
#
# Usage: ./T07-kiosk-services.sh
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

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T07 - Kiosk & Media Services Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T07.1 - Display Manager & X11
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.1 - Display Manager (LightDM)"
check_service_active "display-manager.service"

# ────────────────────────────────────────────────────────────────────────────────
# T07.2 - Kiosk User
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.2 - Kiosk User Session"
if id "kiosk" >/dev/null 2>&1; then
  pass "Kiosk user exists"
  if pgrep -u kiosk -f "openbox" >/dev/null 2>&1; then
    pass "Openbox is running for kiosk user"
  else
    echo -e "${YELLOW}  ⚠️ INFO: Openbox is NOT running for kiosk user (might not be logged in)${NC}"
  fi
else
  fail "Kiosk user does NOT exist"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.3 - VLC Media Player
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.3 - VLC availability"
if command -v vlc >/dev/null 2>&1; then
  pass "VLC is installed and in PATH"
else
  fail "VLC is NOT installed or NOT in PATH"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.4 - MQTT Volume Control Service
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.4 - MQTT Volume Control"
check_service_active "mqtt-volume-control.service"

# Check secrets for volume control
print_test "T07.5 - Media Secrets"
if [[ -f "/etc/secrets/mqtt.env" ]]; then
  pass "MQTT secrets file exists"
else
  fail "MQTT secrets file missing (/etc/secrets/mqtt.env)"
fi

if [[ -f "/etc/secrets/tapoC210-00.env" ]]; then
  pass "Tapo camera secrets file exists"
else
  fail "Tapo camera secrets file missing (/etc/secrets/tapoC210-00.env)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.6 - Audio Configuration
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.6 - Audio System"
if systemctl is-active --user --quiet pulseaudio || pgrep pulseaudio >/dev/null 2>&1; then
  pass "PulseAudio is running"
else
  echo -e "${YELLOW}  ⚠️ INFO: PulseAudio is NOT detected (required for HomePod audio)${NC}"
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
