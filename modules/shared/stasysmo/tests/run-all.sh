#!/usr/bin/env bash
#
# StaSysMo Test Runner - Runs all automated tests
#
# Usage:
#   ./run-all.sh          # Run all tests
#   VERBOSE=1 ./run-all.sh  # Run with verbose output
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE="${VERBOSE:-0}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Platform detection
PLATFORM="unknown"
if [[ "$(uname)" == "Darwin" ]]; then
  PLATFORM="macOS"
elif [[ -f /etc/os-release ]]; then
  PLATFORM="Linux"
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              StaSysMo Test Suite                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo
echo "Platform: $PLATFORM"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Run a test
run_test() {
  local test_script="$1"
  local test_name
  test_name=$(basename "$test_script" .sh)

  if [[ ! -x "$test_script" ]]; then
    chmod +x "$test_script"
  fi

  echo -n "Running $test_name... "

  if [[ "$VERBOSE" == "1" ]]; then
    echo
    if "$test_script"; then
      echo -e "${GREEN}✅ PASS${NC}"
      ((PASSED++))
    else
      echo -e "${RED}❌ FAIL${NC}"
      ((FAILED++))
    fi
  else
    if "$test_script" &>/dev/null; then
      echo -e "${GREEN}✅ PASS${NC}"
      ((PASSED++))
    else
      echo -e "${RED}❌ FAIL${NC}"
      ((FAILED++))
    fi
  fi
}

# Find and run all test scripts
for test_script in "$SCRIPT_DIR"/T*.sh; do
  if [[ -f "$test_script" ]]; then
    run_test "$test_script"
  fi
done

# Summary
echo
echo "════════════════════════════════════════════════════════════════════"
echo "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}$SKIPPED skipped${NC}"
echo "════════════════════════════════════════════════════════════════════"

# Exit with failure if any tests failed
if [[ $FAILED -gt 0 ]]; then
  exit 1
fi

exit 0
