#!/usr/bin/env bash
# T06: CLI Tools - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T06: CLI Tools Test ==="
echo

TOOLS=("bat" "rg" "fd" "fzf" "btop" "zoxide" "jq" "tldr")

for tool in "${TOOLS[@]}"; do
  echo -n "Test: $tool installed... "
  if command -v "$tool" >/dev/null 2>&1; then
    TOOL_PATH=$(which "$tool")
    if [[ "$TOOL_PATH" == *".nix-profile"* ]]; then
      echo -e "${GREEN}✅ PASS${NC} (from Nix)"
    else
      echo -e "${GREEN}✅ PASS${NC} ($TOOL_PATH)"
    fi
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
done

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
