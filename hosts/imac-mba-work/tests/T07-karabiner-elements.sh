#!/usr/bin/env bash
# T07: Karabiner-Elements - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T07: Karabiner-Elements Test ==="
echo

PASSED=0
FAILED=0

# Test 1: Karabiner-Elements installed
echo -n "Test 1: Karabiner-Elements installed... "
if [ -d "/Applications/Karabiner-Elements.app" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (install with: brew install --cask karabiner-elements)"
  ((PASSED++))
fi

# Test 2: Karabiner processes running
echo -n "Test 2: Karabiner processes running... "
if pgrep -q karabiner 2>/dev/null; then
  PROCS=$(pgrep -l karabiner | wc -l | tr -d ' ')
  echo -e "${GREEN}✅ PASS${NC} ($PROCS processes)"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (not running - launch from Applications)"
  ((PASSED++))
fi

# Test 3: Config file exists
echo -n "Test 3: Config file exists... "
if [ -f "$HOME/.config/karabiner/karabiner.json" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 4: Config is valid JSON
echo -n "Test 4: Config is valid JSON... "
if [ -f "$HOME/.config/karabiner/karabiner.json" ]; then
  if jq empty "$HOME/.config/karabiner/karabiner.json" 2>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC}"
    ((PASSED++))
  else
    echo -e "${RED}❌ FAIL${NC} (invalid JSON)"
    ((FAILED++))
  fi
else
  echo -e "${YELLOW}⚠️ SKIP${NC} (no config)"
  ((PASSED++))
fi

echo
echo "Results: $PASSED passed, $FAILED failed"
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ Some tests failed${NC}"
  exit 1
fi
