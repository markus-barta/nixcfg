#!/usr/bin/env bash
# T01: Fish Shell - Automated Test
# Tests Fish shell installation and uzumaki functions
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T01: Fish Shell Test ==="
echo

# Test 1: Fish installed
echo -n "Test 1: Fish installed... "
if command -v fish >/dev/null 2>&1; then
  VERSION=$(fish --version)
  echo -e "${GREEN}✅ PASS${NC} ($VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Fish from Nix
echo -n "Test 2: Fish from Nix... "
FISH_PATH=$(which fish)
if [[ "$FISH_PATH" == *".nix-profile"* ]] || [[ "$FISH_PATH" == *"/nix/store"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($FISH_PATH)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (not from Nix: $FISH_PATH)"
fi

# Test 3: Fish as default shell (optional)
echo -n "Test 3: Fish as default shell... "
if [[ "$SHELL" == *"fish"* ]]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  WARN${NC} ($SHELL - run chsh to change)"
fi

# Test 4: Core uzumaki functions
echo "Test 4: Core uzumaki functions..."
CORE_FUNCTIONS=(pingt sourcefish stress helpfish stasysmod hostcolors hostsecrets)
for func in "${CORE_FUNCTIONS[@]}"; do
  echo -n "  $func... "
  if fish -c "functions -q $func" 2>/dev/null; then
    echo -e "${GREEN}✅${NC}"
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
done

# Test 5: brewall function (macOS-specific)
echo -n "Test 5: brewall function... "
if fish -c "functions -q brewall" 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${YELLOW}⚠️  WARN${NC} (optional)"
fi

# Test 6: pingt produces timestamped output
echo -n "Test 6: pingt timestamps... "
PINGT_OUTPUT=$(fish -c "pingt -c 1 127.0.0.1" 2>&1 || true)
if echo "$PINGT_OUTPUT" | grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 7: hostcolors shows categories
echo -n "Test 7: hostcolors output... "
HOSTCOLORS_OUTPUT=$(fish -c "hostcolors" 2>&1 || true)
if echo "$HOSTCOLORS_OUTPUT" | grep -q "WORKSTATIONS"; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 8: SSH shortcuts
echo "Test 8: SSH shortcuts..."
SSH_ALIASES=(hsb0 hsb1 hsb8 gpc0 mbpw csb0 csb1)
for alias in "${SSH_ALIASES[@]}"; do
  echo -n "  $alias... "
  if fish -c "alias" 2>/dev/null | grep -q "^$alias "; then
    echo -e "${GREEN}✅${NC}"
  else
    echo -e "${YELLOW}⚠️${NC}"
  fi
done

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
