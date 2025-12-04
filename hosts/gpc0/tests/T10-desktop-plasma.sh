#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T10 - Desktop Plasma Integration - Automated Tests              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests KDE Plasma desktop environment integration on gpc0
#
# Usage: ./T10-desktop-plasma.sh
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

print_header "T10 - Desktop Plasma Integration Tests"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T10.1 - Display Manager Service
# ────────────────────────────────────────────────────────────────────────────────

print_test "T10.1 - Display Manager Service"

if systemctl is-active --quiet display-manager 2>/dev/null; then
  pass "display-manager service is active"
else
  fail "display-manager service is not active"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T10.2 - X Server or Wayland
# ────────────────────────────────────────────────────────────────────────────────

print_test "T10.2 - Display Server"

if [[ -n "${DISPLAY:-}" ]]; then
  pass "X11 DISPLAY is set: $DISPLAY"
elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  pass "Wayland DISPLAY is set: $WAYLAND_DISPLAY"
else
  fail "No display server detected (DISPLAY and WAYLAND_DISPLAY both unset)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T10.3 - Plasma Session
# ────────────────────────────────────────────────────────────────────────────────

print_test "T10.3 - Plasma Session"

if pgrep -x plasmashell &>/dev/null; then
  pass "plasmashell is running"
else
  fail "plasmashell is not running (Plasma desktop not loaded?)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T10.4 - KDE Applications
# ────────────────────────────────────────────────────────────────────────────────

print_test "T10.4 - Core KDE Applications"

if command -v konsole &>/dev/null; then
  pass "Konsole terminal available"
else
  fail "Konsole not found"
fi

if command -v dolphin &>/dev/null; then
  pass "Dolphin file manager available"
else
  fail "Dolphin not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T10.5 - Audio System
# ────────────────────────────────────────────────────────────────────────────────

print_test "T10.5 - Audio System"

if systemctl --user is-active --quiet pipewire 2>/dev/null; then
  pass "PipeWire is active"
elif systemctl --user is-active --quiet pulseaudio 2>/dev/null; then
  pass "PulseAudio is active"
else
  fail "No audio server (PipeWire/PulseAudio) detected"
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
