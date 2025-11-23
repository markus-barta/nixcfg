#!/usr/bin/env bash
# T04: Python - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T04: Python Test ==="
echo

# Test 1: Python installed
echo -n "Test 1: Python installed... "
if command -v python3 >/dev/null 2>&1; then
  PYTHON_VERSION=$(python3 --version)
  echo -e "${GREEN}✅ PASS${NC} ($PYTHON_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

# Test 2: Python from Nix
echo -n "Test 2: Python from Nix... "
PYTHON_PATH=$(which python3)
if [[ "$PYTHON_PATH" == *".nix-profile"* ]]; then
  echo -e "${GREEN}✅ PASS${NC} ($PYTHON_PATH)"
else
  echo -e "${RED}❌ FAIL${NC} (found at $PYTHON_PATH)"
  exit 1
fi

# Test 3: pip installed
echo -n "Test 3: pip installed... "
if command -v pip3 >/dev/null 2>&1; then
  PIP_VERSION=$(pip3 --version | awk '{print $2}')
  echo -e "${GREEN}✅ PASS${NC} (v$PIP_VERSION)"
else
  echo -e "${RED}❌ FAIL${NC}"
  exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
