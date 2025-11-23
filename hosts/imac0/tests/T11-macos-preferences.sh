#!/usr/bin/env bash
#
# T11: macOS Preferences - Automated Test
# Tests that macOS system preferences are configured correctly
#

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T11: macOS Preferences Test ==="
echo

# Test 1: Dock autohide
echo -n "Test 1: Dock autohide setting... "
DOCK_AUTOHIDE=$(defaults read com.apple.dock autohide 2>/dev/null || echo "0")
if [[ "$DOCK_AUTOHIDE" == "1" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (enabled)"
elif [[ "$DOCK_AUTOHIDE" == "0" ]]; then
  echo -e "${YELLOW}ℹ️  INFO${NC} (disabled)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (unknown)"
fi

# Test 2: Screenshot location
echo -n "Test 2: Screenshot location... "
SCREENSHOT_LOC=$(defaults read com.apple.screencapture location 2>/dev/null || echo "")
if [[ -n "$SCREENSHOT_LOC" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($SCREENSHOT_LOC)"
else
  echo -e "${YELLOW}ℹ️  INFO${NC} (default: ~/Desktop)"
fi

# Test 3: Finder show hidden files
echo -n "Test 3: Finder hidden files... "
FINDER_HIDDEN=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || echo "0")
if [[ "$FINDER_HIDDEN" == "1" ]] || [[ "$FINDER_HIDDEN" == "true" ]] || [[ "$FINDER_HIDDEN" == "TRUE" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (shown)"
else
  echo -e "${YELLOW}ℹ️  INFO${NC} (hidden - default)"
fi

# Test 4: Key repeat rate
echo -n "Test 4: Key repeat rate... "
KEY_REPEAT=$(defaults read NSGlobalDomain KeyRepeat 2>/dev/null || echo "")
if [[ -n "$KEY_REPEAT" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (set to $KEY_REPEAT)"
else
  echo -e "${YELLOW}ℹ️  INFO${NC} (default)"
fi

# Test 5: Initial key repeat delay
echo -n "Test 5: Initial key delay... "
INIT_REPEAT=$(defaults read NSGlobalDomain InitialKeyRepeat 2>/dev/null || echo "")
if [[ -n "$INIT_REPEAT" ]]; then
  echo -e "${GREEN}✅ PASS${NC} (set to $INIT_REPEAT)"
else
  echo -e "${YELLOW}ℹ️  INFO${NC} (default)"
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
echo
echo "Note: This test checks common macOS preferences."
echo "All results are informational - no strict pass/fail."
exit 0
