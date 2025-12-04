#!/usr/bin/env bash
#
# T02: Output Files - Automated Test
# Tests that daemon writes metrics to the correct directory
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== T02: Output Files Test ==="
echo

# Set directory based on platform
PLATFORM="$(uname)"
if [[ "$PLATFORM" == "Darwin" ]]; then
  STASYSMO_DIR="/tmp/stasysmo"
else
  STASYSMO_DIR="/dev/shm/stasysmo"
fi

echo "Platform: $PLATFORM"
echo "Directory: $STASYSMO_DIR"
echo

# Test 1: Directory exists
echo -n "Test 1: Output directory exists... "
if [[ -d "$STASYSMO_DIR" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  echo "  Directory not found. Is the daemon running?"
  exit 1
fi

# Test 2: All metric files exist
echo -n "Test 2: Metric files exist... "
MISSING=""
for file in cpu ram load swap timestamp; do
  if [[ ! -f "$STASYSMO_DIR/$file" ]]; then
    MISSING="$MISSING $file"
  fi
done

if [[ -z "$MISSING" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (Missing:$MISSING)"
  exit 1
fi

# Test 3: Files contain valid data
echo -n "Test 3: CPU value valid... "
CPU=$(cat "$STASYSMO_DIR/cpu")
if [[ "$CPU" =~ ^[0-9]+$ ]] && [[ "$CPU" -ge 0 ]] && [[ "$CPU" -le 100 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($CPU%)"
else
  echo -e "${RED}❌ FAIL${NC} (Invalid: $CPU)"
  exit 1
fi

echo -n "Test 4: RAM value valid... "
RAM=$(cat "$STASYSMO_DIR/ram")
if [[ "$RAM" =~ ^[0-9]+$ ]] && [[ "$RAM" -ge 0 ]] && [[ "$RAM" -le 100 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($RAM%)"
else
  echo -e "${RED}❌ FAIL${NC} (Invalid: $RAM)"
  exit 1
fi

echo -n "Test 5: Load value valid... "
LOAD=$(cat "$STASYSMO_DIR/load")
if [[ "$LOAD" =~ ^[0-9]+\.?[0-9]*$ ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($LOAD)"
else
  echo -e "${RED}❌ FAIL${NC} (Invalid: $LOAD)"
  exit 1
fi

echo -n "Test 6: Swap value valid... "
SWAP=$(cat "$STASYSMO_DIR/swap")
if [[ "$SWAP" =~ ^[0-9]+$ ]] && [[ "$SWAP" -ge 0 ]] && [[ "$SWAP" -le 100 ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($SWAP%)"
else
  echo -e "${RED}❌ FAIL${NC} (Invalid: $SWAP)"
  exit 1
fi

echo -n "Test 7: Timestamp is recent... "
TIMESTAMP=$(cat "$STASYSMO_DIR/timestamp")
NOW=$(date +%s)
AGE=$((NOW - TIMESTAMP))
if [[ "$AGE" -lt 15 ]]; then
  echo -e "${GREEN}✅ PASS${NC} (${AGE}s old)"
else
  echo -e "${YELLOW}⚠️ WARN${NC} (${AGE}s old - may be stale)"
fi

echo
echo -e "${GREEN}🎉 Output file tests passed!${NC}"
exit 0
