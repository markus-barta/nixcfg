#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              Uzumaki Migration - Baseline Test Collection                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Collects baseline test results from all Phase I hosts before migration.
# Run this from your workstation (imac0 or mba-imac-work).
#
# Usage: ./collect-baselines.sh [host]
#   ./collect-baselines.sh        # Run all hosts
#   ./collect-baselines.sh hsb1   # Run only hsb1
#
# Results saved to: tests/baselines/YYYYMMDD-<host>.log
#

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_DIR="$SCRIPT_DIR/baselines"
DATE=$(date +%Y%m%d)

# Host configurations (SSH targets for remote NixOS hosts)
get_ssh_target() {
  local host="$1"
  case "$host" in
  hsb0) echo "mba@192.168.1.99" ;;
  hsb1) echo "mba@192.168.1.101" ;;
  hsb8) echo "mba@192.168.1.100" ;;
  gpc0) echo "mba@192.168.1.154" ;;
  *) echo "" ;;
  esac
}

# Create baseline directory
mkdir -p "$BASELINE_DIR"

# ════════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════════════════════

print_header() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  $1${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
}

run_remote_tests() {
  local host="$1"
  local ssh_target
  ssh_target=$(get_ssh_target "$host")
  local logfile="$BASELINE_DIR/${DATE}-${host}.log"

  if [[ -z "$ssh_target" ]]; then
    echo -e "${YELLOW}⏭️  No SSH target configured for $host${NC}"
    return 1
  fi

  echo -e "${YELLOW}Running tests on $host ($ssh_target)...${NC}"

  # Check SSH connectivity first
  if ! ssh -o ConnectTimeout=5 "$ssh_target" 'echo "connected"' &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to $host ($ssh_target)${NC}"
    echo "SKIPPED - Cannot connect" >"$logfile"
    return 1
  fi

  # Run tests remotely (nixcfg is in ~/Code/nixcfg on all hosts)
  # shellcheck disable=SC2029
  ssh "$ssh_target" "cd ~/Code/nixcfg/hosts/$host/tests && ./run-all-tests.sh" 2>&1 | tee "$logfile"

  # Check result
  if grep -q "ALL TESTS PASSED" "$logfile"; then
    echo -e "${GREEN}✅ $host: ALL TESTS PASSED${NC}"
    return 0
  else
    echo -e "${RED}❌ $host: SOME TESTS FAILED${NC}"
    return 1
  fi
}

run_local_tests() {
  local host="$1"
  local test_dir="$SCRIPT_DIR/../hosts/$host/tests"
  local logfile="$BASELINE_DIR/${DATE}-${host}.log"

  echo -e "${YELLOW}Running tests locally for $host...${NC}"

  if [[ ! -d "$test_dir" ]]; then
    echo -e "${RED}❌ Test directory not found: $test_dir${NC}"
    echo "SKIPPED - Test directory not found" >"$logfile"
    return 1
  fi

  # Run tests locally
  (cd "$test_dir" && ./run-all-tests.sh) 2>&1 | tee "$logfile"

  # Check result
  if grep -q "ALL TESTS PASSED" "$logfile"; then
    echo -e "${GREEN}✅ $host: ALL TESTS PASSED${NC}"
    return 0
  else
    echo -e "${RED}❌ $host: SOME TESTS FAILED${NC}"
    return 1
  fi
}

detect_current_host() {
  hostname -s 2>/dev/null || hostname
}

# ════════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════════

print_header "Uzumaki Migration - Baseline Test Collection"

echo "Date: $(date)"
echo "Baseline Directory: $BASELINE_DIR"
echo ""

CURRENT_HOST=$(detect_current_host)
echo "Current host: $CURRENT_HOST"
echo ""

# Determine which hosts to test
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("hsb1" "hsb0" "hsb8" "gpc0" "imac0" "mba-imac-work")
fi

# Results tracking
PASSED=0
FAILED=0
SKIPPED=0

for host in "${TARGETS[@]}"; do
  print_header "Testing: $host"

  # Check if this is the current host (run locally) or remote
  if [[ "$host" == "$CURRENT_HOST" ]] || [[ "$host" == "imac0" && "$CURRENT_HOST" == "imac0"* ]] || [[ "$host" == "mba-imac-work" && "$CURRENT_HOST" == *"mba-work"* ]]; then
    if run_local_tests "$host"; then
      ((PASSED++))
    else
      ((FAILED++))
    fi
  elif [[ -n "$(get_ssh_target "$host")" ]]; then
    if run_remote_tests "$host"; then
      ((PASSED++))
    else
      ((FAILED++))
    fi
  else
    echo -e "${YELLOW}⏭️  Skipping $host (not configured for remote testing)${NC}"
    ((SKIPPED++))
  fi
done

# ════════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════════

print_header "Baseline Collection Summary"

echo ""
echo -e "  ${GREEN}Passed:  $PASSED${NC}"
echo -e "  ${RED}Failed:  $FAILED${NC}"
echo -e "  ${YELLOW}Skipped: $SKIPPED${NC}"
echo ""
echo "Baseline logs saved to: $BASELINE_DIR/"
ls -la "$BASELINE_DIR"/"${DATE}"-*.log 2>/dev/null || echo "  (no logs yet)"
echo ""

if [[ $FAILED -eq 0 && $SKIPPED -eq 0 ]]; then
  echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✅ ALL BASELINES COLLECTED SUCCESSFULLY${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════${NC}"
  exit 0
elif [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${RED}  ❌ SOME HOSTS FAILED - Review logs before migration${NC}"
  echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
  exit 1
else
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  ⚠️  SOME HOSTS SKIPPED - Run manually on those hosts${NC}"
  echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
  exit 0
fi
