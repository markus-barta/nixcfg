#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     hsb8 - Run All Tests                                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Runs all test scripts in order and reports results
#
# Usage: ./run-all-tests.sh
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Results tracking
TOTAL=0
PASSED=0
FAILED=0
declare -a FAILED_TESTS=()

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                     hsb8 Test Suite                                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Host: $(hostname)"
echo "Date: $(date)"
echo "Test Directory: $SCRIPT_DIR"
echo ""

# Run each test in order
for test_script in "$SCRIPT_DIR"/T*.sh; do
  if [[ -x "$test_script" ]]; then
    test_name=$(basename "$test_script")
    ((TOTAL++)) || true

    echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Running: $test_name${NC}"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────────────────────────${NC}"

    if "$test_script"; then
      ((PASSED++)) || true
      echo -e "${GREEN}✅ $test_name PASSED${NC}"
    else
      ((FAILED++)) || true
      FAILED_TESTS+=("$test_name")
      echo -e "${RED}❌ $test_name FAILED${NC}"
    fi
    echo ""
  fi
done

# Summary
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                              FINAL SUMMARY${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Total Tests: ${TOTAL}"
echo -e "  ${GREEN}Passed:       ${PASSED}${NC}"
echo -e "  ${RED}Failed:       ${FAILED}${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}Failed Tests:${NC}"
  for t in "${FAILED_TESTS[@]}"; do
    echo -e "  ${RED}• $t${NC}"
  done
  echo ""
  echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${RED}                         ❌ SOME TESTS FAILED${NC}"
  echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
  exit 1
else
  echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}                         ✅ ALL TESTS PASSED${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════${NC}"
  exit 0
fi
