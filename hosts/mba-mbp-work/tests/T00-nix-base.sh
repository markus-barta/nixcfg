#!/usr/bin/env bash
# T00: Nix Base System - Automated Test
# Tests Nix installation, flakes, and home-manager
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T00: Nix Base System Test ==="
echo

# Test 1: Nix installed
echo -n "Test 1: Nix installed... "
if command -v nix >/dev/null 2>&1; then
  NIX_VERSION=$(nix --version)
  echo -e "${GREEN}✅ PASS${NC} ($NIX_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Flakes enabled
echo -n "Test 2: Flakes enabled... "
if nix flake --help >/dev/null 2>&1; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 3: home-manager available
echo -n "Test 3: home-manager available... "
if command -v home-manager >/dev/null 2>&1; then
  HM_VERSION=$(home-manager --version)
  echo -e "${GREEN}✅ PASS${NC} ($HM_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 4: Platform detection (requires --impure)
echo -n "Test 4: Platform detection... "
PLATFORM=$(nix eval --impure --expr 'builtins.currentSystem' 2>/dev/null | tr -d '"')
if [[ "$PLATFORM" == "x86_64-darwin" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($PLATFORM - Intel Mac)"
elif [[ "$PLATFORM" == "aarch64-darwin" ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($PLATFORM - Apple Silicon)"
else
  echo -e "${YELLOW}⚠️  WARN${NC} ($PLATFORM)"
fi

# Test 5: Nix store accessible
echo -n "Test 5: Nix store accessible... "
if [[ -d /nix/store ]]; then
  STORE_COUNT=$(find /nix/store -maxdepth 1 -type d | wc -l | tr -d ' ')
  echo -e "${GREEN}✅ PASS${NC} ($STORE_COUNT items)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
