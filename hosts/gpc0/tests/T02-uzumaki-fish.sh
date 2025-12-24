#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T02 - Uzumaki Fish Functions - Automated Tests                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests fish functions provided by modules/uzumaki (pingt, stress, helpfish, etc.)
# These functions are defined in uzumaki/common.nix and exported via server.nix/desktop.nix
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

# Check if a fish abbreviation exists
check_fish_abbr() {
  local abbr_name="$1"
  local expected="$2"
  local description="$3"

  # Abbreviations are defined in interactiveShellInit, so we check the config file
  if grep -q "abbr.*$abbr_name.*$expected" /etc/fish/config.fish 2>/dev/null; then
    pass "$description"
    return 0
  else
    fail "$description (not found in config.fish)"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T02 - Uzumaki Fish Functions Tests"

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
check_fish_function "stress" "stress function exists"
check_fish_function "helpfish" "helpfish function exists"

# ────────────────────────────────────────────────────────────────────────────────
# T02.3 - Function Descriptions
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.3 - Function Descriptions"

# Check that functions have descriptions in config.fish
if grep -q "function pingt --description" /etc/fish/config.fish 2>/dev/null; then
  pass "pingt has description"
else
  fail "pingt missing description"
fi

if grep -q "function stress --description" /etc/fish/config.fish 2>/dev/null; then
  pass "stress has description"
else
  fail "stress missing description"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.4 - pingt Function Works
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.4 - pingt Function Works"

# Check pingt definition in config.fish
if grep -A15 "function pingt" /etc/fish/config.fish 2>/dev/null | grep -q "date"; then
  pass "pingt function includes timestamp (date) call"
else
  fail "pingt function doesn't include timestamp"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.5 - stress Function Definition
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.5 - stress Function Definition"

# stress with no args should show core count message
if grep -A10 "function stress" /etc/fish/config.fish 2>/dev/null | grep -qE "nproc|cores"; then
  pass "stress function includes core count logic"
else
  fail "stress function doesn't include core count logic"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.6 - helpfish Function Output
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.6 - helpfish Function Output"

# helpfish runs in interactive mode, so we check config.fish for the function
if grep -q "function helpfish" /etc/fish/config.fish 2>/dev/null; then
  pass "helpfish function defined"
else
  fail "helpfish function not found"
fi

# Check that helpfish references sections in its output definition
if grep -A100 "function helpfish" /etc/fish/config.fish 2>/dev/null | grep -q "Functions"; then
  pass "helpfish has Functions section"
else
  fail "helpfish missing Functions section"
fi

if grep -A100 "function helpfish" /etc/fish/config.fish 2>/dev/null | grep -q "Abbreviations"; then
  pass "helpfish has Abbreviations section"
else
  fail "helpfish missing Abbreviations section"
fi

if grep -A100 "function helpfish" /etc/fish/config.fish 2>/dev/null | grep -q "pingt"; then
  pass "helpfish lists pingt"
else
  fail "helpfish doesn't list pingt"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.7 - sourcefish Function Exists
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.7 - sourcefish Function Exists"

if grep -q "function sourcefish" /etc/fish/config.fish 2>/dev/null; then
  pass "sourcefish function exists"
else
  fail "sourcefish function missing"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.8 - Key Abbreviations Set
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.8 - Key Abbreviations"

check_fish_abbr "ping" "pingt" "ping → pingt abbreviation"
check_fish_abbr "tmux" "zellij" "tmux → zellij abbreviation"
check_fish_abbr "vim" "hx" "vim → hx abbreviation"

# ────────────────────────────────────────────────────────────────────────────────
# T02.9 - EDITOR Environment Variable
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.9 - EDITOR Environment Variable"

# shellcheck disable=SC2016
EDITOR_VALUE=$(fish -c 'echo $EDITOR' 2>/dev/null || true)
if [[ "$EDITOR_VALUE" == "nano" ]]; then
  pass "EDITOR is set to nano"
else
  fail "EDITOR is '$EDITOR_VALUE' (expected: nano)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T02.10 - Zellij Available
# ────────────────────────────────────────────────────────────────────────────────

print_test "T02.10 - Zellij Available"

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
