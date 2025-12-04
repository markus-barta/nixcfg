#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T20 - Uzumaki Fish Functions - Automated Tests                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests fish functions provided by modules/uzumaki (pingt, stress, helpfish, etc.)
# Run this test locally on hsb8.
#
# Usage: ./T20-uzumaki-fish.sh
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

print_header "T20 - Uzumaki Fish Functions Tests (hsb8)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T20.1 - Fish Shell Available
# ────────────────────────────────────────────────────────────────────────────────

print_test "T20.1 - Fish Shell Available"

if command -v fish &>/dev/null; then
  VERSION=$(fish --version)
  pass "Fish installed: $VERSION"
else
  fail "Fish not found!"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────────
# T20.2 - Uzumaki Functions Exist
# ────────────────────────────────────────────────────────────────────────────────

print_test "T20.2 - Uzumaki Functions Exist"

check_fish_function "pingt" "pingt function exists"
check_fish_function "sourcefish" "sourcefish function exists"
check_fish_function "sourceenv" "sourceenv function exists"
check_fish_function "stress" "stress function exists"
check_fish_function "helpfish" "helpfish function exists"

# ────────────────────────────────────────────────────────────────────────────────
# T20.3 - pingt Function Works
# ────────────────────────────────────────────────────────────────────────────────

print_test "T20.3 - pingt Function Works"

# Run pingt with -c 1 (single ping) and check for timestamp output
PINGT_OUTPUT=$(fish -c "pingt -c 1 127.0.0.1" 2>&1 || true)
if echo "$PINGT_OUTPUT" | grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
  pass "pingt adds timestamps to output"
else
  fail "pingt doesn't add timestamps"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T20.4 - helpfish Function Output
# ────────────────────────────────────────────────────────────────────────────────

print_test "T20.4 - helpfish Function Output"

HELPFISH_OUTPUT=$(fish -c "helpfish" 2>&1 || true)

if echo "$HELPFISH_OUTPUT" | grep -q "Functions"; then
  pass "helpfish shows Functions section"
else
  fail "helpfish missing Functions section"
fi

if echo "$HELPFISH_OUTPUT" | grep -q "pingt"; then
  pass "helpfish lists pingt"
else
  fail "helpfish doesn't list pingt"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T20.5 - Key Abbreviations Set
# ────────────────────────────────────────────────────────────────────────────────

print_test "T20.5 - Key Abbreviations"

# Check ping→pingt abbreviation
if fish -c "abbr --show" 2>/dev/null | grep -q "ping.*pingt"; then
  pass "ping → pingt abbreviation"
else
  fail "ping → pingt abbreviation not found"
fi

# Check tmux→zellij abbreviation
if fish -c "abbr --show" 2>/dev/null | grep -q "tmux.*zellij"; then
  pass "tmux → zellij abbreviation"
else
  fail "tmux → zellij abbreviation not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T20.6 - Zellij Available
# ────────────────────────────────────────────────────────────────────────────────

print_test "T20.6 - Zellij Available"

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
