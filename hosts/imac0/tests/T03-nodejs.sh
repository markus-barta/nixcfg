#!/usr/bin/env bash
# T03: Node.js - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T03: Node.js Test ==="
echo

# Test 1: Node.js installed
echo -n "Test 1: Node.js installed... "
if command -v node >/dev/null 2>&1; then
  NODE_VERSION=$(node --version)
  echo -e "${GREEN}✅ PASS${NC} ($NODE_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Node from Nix
echo -n "Test 2: Node from Nix... "
NODE_PATH=$(which node)
if [[ "$NODE_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($NODE_PATH)"
else
  echo -e "${RED}❌ FAIL${NC} (found at $NODE_PATH)"
  exit 1
fi

# Test 3: npm installed
echo -n "Test 3: npm installed... "
if command -v npm >/dev/null 2>&1; then
  NPM_VERSION=$(npm --version)
  echo -e "${GREEN}✅ PASS${NC} (v$NPM_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
