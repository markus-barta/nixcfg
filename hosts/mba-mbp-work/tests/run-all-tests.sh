#!/usr/bin/env bash
#
# Run all tests for mba-mbp-work
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo " mba-mbp-work Test Suite"
echo "=========================================="
echo

PASSED=0
FAILED=0
SKIPPED=0

run_test() {
  local test_file="$1"
  local test_name="$2"

  if [[ ! -f "$test_file" ]]; then
    echo -e "${YELLOW}⏭️  SKIP${NC}: $test_name (file not found)"
    ((SKIPPED++))
    return
  fi

  if [[ ! -x "$test_file" ]]; then
    chmod +x "$test_file"
  fi

  echo "Running: $test_name"
  echo "---"

  if "./$test_file"; then
    echo -e "${GREEN}✅ PASS${NC}: $test_name"
    ((PASSED++))
  else
    echo -e "${RED}❌ FAIL${NC}: $test_name"
    ((FAILED++))
  fi
  echo
}

# Run available tests
run_test "T00-nix-base.sh" "T00: Nix Base System"
run_test "T01-fish-shell.sh" "T01: Fish Shell"
run_test "T05-direnv.sh" "T05: direnv + devenv"
run_test "T07-gui-apps.sh" "T07: GUI Applications"

# Summary
echo "=========================================="
echo " Summary"
echo "=========================================="
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo

if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ Some tests failed${NC}"
  exit 1
fi
