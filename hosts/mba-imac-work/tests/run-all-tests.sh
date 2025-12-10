#!/usr/bin/env bash
# Run all mba-imac-work tests
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Timeout per test (seconds)
TEST_TIMEOUT=30

# Cross-platform timeout function (works on macOS and Linux)
run_with_timeout() {
  local timeout=$1
  shift

  # Try gtimeout (Homebrew coreutils), then timeout (Linux/Nix), then fallback
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" "$@"
  else
    # Fallback: run without timeout
    "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "  mba-imac-work Test Suite"
echo "  (timeout: ${TEST_TIMEOUT}s per test)"
echo "========================================"
echo

TOTAL_PASSED=0
TOTAL_FAILED=0
RESULTS=()

for test_script in T*.sh; do
  if [ "$test_script" = "run-all-tests.sh" ]; then
    continue
  fi

  TEST_NAME=$(basename "$test_script" .sh)
  echo "Running $TEST_NAME..."
  echo "----------------------------------------"

  if run_with_timeout "$TEST_TIMEOUT" ./"$test_script"; then
    RESULTS+=("✅ $TEST_NAME")
    ((TOTAL_PASSED++))
  else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
      RESULTS+=("⏱️ $TEST_NAME (timeout)")
    else
      RESULTS+=("❌ $TEST_NAME")
    fi
    ((TOTAL_FAILED++))
  fi
  echo
done

echo "========================================"
echo "  Summary"
echo "========================================"
echo

for result in "${RESULTS[@]}"; do
  echo "  $result"
done

echo
echo "----------------------------------------"
echo "Total: $TOTAL_PASSED passed, $TOTAL_FAILED failed"

if [ $TOTAL_FAILED -eq 0 ]; then
  echo -e "${GREEN}🎉 All test suites passed!${NC}"
  exit 0
else
  echo -e "${YELLOW}⚠️ Some tests failed - check output above${NC}"
  exit 1
fi
