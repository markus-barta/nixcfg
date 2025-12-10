#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T02 - Uzumaki Fish Functions - Automated Tests                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests fish functions provided by modules/uzumaki (pingt, stress, helpfish, etc.)
# These functions are defined in uzumaki/common.nix and exported via server.nix
#
# Usage: ./T02-uzumaki-fish.sh
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

# Check if a fish function exists
# NOTE: Functions defined in interactiveShellInit aren't available in non-interactive
# shells, so we check the config file directly instead of using `functions -q`
check_fish_function() {
  local func_name="$1"
  local description="$2"

  # Check if function is defined in the fish config (handles interactiveShellInit)
  if grep -q "function $func_name" /etc/fish/config.fish 2>/dev/null; then
    pass "$description"
    return 0
  else
    fail "$description"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T02 - Uzumaki Fish Functions Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T02.1 - Fish Shell Available
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.1 - Fish Shell Available"

if command -v fish &>/dev/null; then
  VERSION=$(fish --version)
  pass "Fish installed: $VERSION"
else
  fail "Fish not found!"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.2 - Uzumaki Functions Exist
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.2 - Uzumaki Functions Exist"

check_fish_function "pingt" "pingt function exists"
check_fish_function "sourcefish" "sourcefish function exists"
check_fish_function "helpfish" "helpfish function exists"

# ────────────────────────────────────────────────────────────────────────────────
# T02.3 - pingt Function Definition
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.3 - pingt Function Definition"

# pingt is defined in interactiveShellInit so we verify the function body
# instead of trying to run it in non-interactive mode
if grep -A15 "function pingt" /etc/fish/config.fish 2>/dev/null | grep -q "date"; then
  pass "pingt function includes timestamp (date) call"
else
  fail "pingt function doesn't include timestamp"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.4 - helpfish Function Output
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.4 - helpfish Function Output"

# helpfish runs in interactive mode, so we check config.fish for the function
if grep -q "function helpfish" /etc/fish/config.fish 2>/dev/null; then
  pass "helpfish function defined"
else
  fail "helpfish function not found"
fi

# Check that helpfish references pingt in its output definition
if grep -A50 "function helpfish" /etc/fish/config.fish 2>/dev/null | grep -q "pingt"; then
  pass "helpfish lists pingt"
else
  fail "helpfish doesn't list pingt"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.5 - Key Abbreviations Set
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.5 - Key Abbreviations"

# Check ping→pingt abbreviation (defined in interactiveShellInit, check config.fish)
if grep -q "abbr.*ping.*pingt" /etc/fish/config.fish 2>/dev/null; then
  pass "ping → pingt abbreviation"
else
  fail "ping → pingt abbreviation not found"
fi

# Check tmux→zellij abbreviation (defined in interactiveShellInit, check config.fish)
if grep -q "abbr.*tmux.*zellij" /etc/fish/config.fish 2>/dev/null; then
  pass "tmux → zellij abbreviation"
else
  fail "tmux → zellij abbreviation not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.6 - Zellij Available
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.6 - Zellij Available"

if command -v zellij &>/dev/null; then
  ZELLIJ_VERSION=$(zellij --version)
  pass "Zellij installed: $ZELLIJ_VERSION"
else
  fail "Zellij not found!"
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
