#!/usr/bin/env bash
#
# T00: Platform Detection - Automated Test
# Tests that platform is correctly detected and paths are set
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T00: Platform Detection Test ==="
echo

# Test 1: Detect platform
echo -n "Test 1: Platform detection... "
PLATFORM="$(uname)"
if [[ "$PLATFORM" == "Darwin" ]] || [[ "$PLATFORM" == "Linux" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($PLATFORM)"
else
  echo -e "${RED}❌ FAIL${NC} (Unknown: $PLATFORM)"
  exit 1
fi

# Test 2: Correct output directory exists or can be created
echo -n "Test 2: Output directory path... "
if [[ "$PLATFORM" == "Darwin" ]]; then
  EXPECTED_DIR="/tmp/stasysmo"
else
  EXPECTED_DIR="/dev/shm/stasysmo"
fi

# Check if parent exists (don't create the dir, just check the path is valid)
PARENT_DIR=$(dirname "$EXPECTED_DIR")
if [[ -d "$PARENT_DIR" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($EXPECTED_DIR)"
else
  echo -e "${RED}❌ FAIL${NC} (Parent not found: $PARENT_DIR)"
  exit 1
fi

# Test 3: Required commands available
echo -n "Test 3: Required commands... "
MISSING=""
for cmd in date cat grep awk; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING="$MISSING $cmd"
  fi
done

if [[ -z "$MISSING" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (Missing:$MISSING)"
  exit 1
fi

# Platform-specific tests
if [[ "$PLATFORM" == "Darwin" ]]; then
  # Test 4a: macOS-specific commands
  echo -n "Test 4: macOS commands (vm_stat, sysctl)... "
  if command -v vm_stat &>/dev/null && command -v sysctl &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
else
  # Test 4b: Linux-specific files
  echo -n "Test 4: Linux /proc files... "
  if [[ -f /proc/stat ]] && [[ -f /proc/meminfo ]] && [[ -f /proc/loadavg ]]; then
    echo -e "${GREEN}✅ PASS${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
fi

echo
echo -e "${GREEN}🎉 All platform tests passed!${NC}"
exit 0
