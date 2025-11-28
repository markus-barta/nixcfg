#!/usr/bin/env bash
# T00: Nix Base System - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== T00: Nix Base System Test ==="
echo

PASSED=0
FAILED=0

# Test 1: Nix installed
echo -n "Test 1: Nix installed... "
if command -v nix >/dev/null 2>&1; then
  NIX_VERSION=$(nix --version)
  echo -e "${GREEN}✅ PASS${NC} ($NIX_VERSION)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 2: Flakes enabled
echo -n "Test 2: Flakes enabled... "
if nix flake --help >/dev/null 2>&1; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 3: home-manager installed
echo -n "Test 3: home-manager installed... "
if command -v home-manager >/dev/null 2>&1; then
  HM_VERSION=$(home-manager --version 2>/dev/null || echo "unknown")
  echo -e "${GREEN}✅ PASS${NC} ($HM_VERSION)"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
fi

# Test 4: home-manager generations exist
echo -n "Test 4: home-manager generations... "
if home-manager generations 2>/dev/null | head -1 | grep -q "id"; then
  GEN_COUNT=$(home-manager generations 2>/dev/null | wc -l | tr -d ' ')
  echo -e "${GREEN}✅ PASS${NC} ($GEN_COUNT generations)"
  ((PASSED++))
else
  echo -e "${YELLOW}⚠️ WARN${NC} (no generations found)"
  ((PASSED++)) # Not critical
fi

# Test 5: Nix profile in PATH
echo -n "Test 5: Nix profile in PATH... "
if echo "$PATH" | tr ':' '\n' | grep -q "nix-profile"; then
  echo -e "${GREEN}✅ PASS${NC}"
  ((PASSED++))
else
  echo -e "${RED}❌ FAIL${NC}"
  ((FAILED++))
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
