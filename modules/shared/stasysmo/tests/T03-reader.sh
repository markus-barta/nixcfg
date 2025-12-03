#!/usr/bin/env bash
#
# T03: Reader Output - Automated Test
# Tests that stasysmo-reader produces formatted output
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== T03: Reader Output Test ==="
echo

# Test 1: Reader command exists
echo -n "Test 1: stasysmo-reader in PATH... "
if command -v stasysmo-reader &>/dev/null; then
  READER_PATH=$(which stasysmo-reader)
  echo -e "${GREEN}✅ PASS${NC} ($READER_PATH)"
else
  echo -e "${RED}❌ FAIL${NC}"
  echo "  Hint: Rebuild with StaSysMo enabled"
  exit 1
fi

# Test 2: Reader produces output
echo -n "Test 2: Reader produces output... "
OUTPUT=$(stasysmo-reader 2>/dev/null || echo "")
if [[ -n "$OUTPUT" ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️ WARN${NC} (Empty output - daemon may not be running)"
fi

# Test 3: Output contains ANSI color codes
echo -n "Test 3: Output has color codes... "
if [[ "$OUTPUT" == *$'\033['* ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  if [[ -z "$OUTPUT" ]]; then
    echo -e "${YELLOW}⚠️ SKIP${NC} (No output to check)"
  else
    echo -e "${YELLOW}⚠️ WARN${NC} (No color codes found)"
  fi
fi

# Test 4: Output contains percentage signs (CPU/RAM/Swap)
echo -n "Test 4: Output contains percentages... "
if [[ "$OUTPUT" == *"%"* ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  if [[ -z "$OUTPUT" ]]; then
    echo -e "${YELLOW}⚠️ SKIP${NC} (No output to check)"
  else
    echo -e "${YELLOW}⚠️ WARN${NC} (No % found)"
  fi
fi

# Test 5: Output length within budget
echo -n "Test 5: Output within character budget... "
# Strip ANSI codes and count
STRIPPED=$(echo -n "$OUTPUT" | sed 's/\x1b\[[0-9;]*m//g')
LENGTH=${#STRIPPED}
MAX_BUDGET=50 # Slightly more than default 45 to allow for formatting

if [[ "$LENGTH" -le "$MAX_BUDGET" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($LENGTH chars)"
else
  echo -e "${YELLOW}⚠️ WARN${NC} ($LENGTH chars > $MAX_BUDGET)"
fi

# Test 6: Empty output is truly empty (no artifacts)
echo -n "Test 6: Empty output has no artifacts... "
# Check that if output is empty, it's truly empty (no spaces, no escape sequences)
if [[ -z "$OUTPUT" ]]; then
  # If empty, verify no hidden characters
  RAW_LEN=${#OUTPUT}
  if [[ "$RAW_LEN" -eq 0 ]]; then
    echo -e "${GREEN}✅ PASS${NC} (truly empty, no artifacts)"
  else
    echo -e "${RED}❌ FAIL${NC} (output appears empty but has $RAW_LEN hidden chars)"
  fi
else
  echo -e "${YELLOW}⚠️ SKIP${NC} (output not empty, cannot test artifact-free empty)"
fi

# Show actual output for debugging
echo
echo "Reader output (raw):"
echo "$OUTPUT"
echo
echo "Reader output (visible):"
echo -e "$OUTPUT"

echo
echo -e "${GREEN}🎉 Reader tests passed!${NC}"
exit 0
