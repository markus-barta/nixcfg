#!/usr/bin/env bash
# T05: CLI Development Tools - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T05: CLI Development Tools Test ==="
echo

PASSED=0
FAILED=0

# List of tools to test
TOOLS=("bat" "rg" "fd" "fzf" "btop" "zoxide" "jq" "just" "cloc" "watch")

# Get version flag for a tool (some need -v instead of --version)
get_version_flag() {
  case "$1" in
  btop | watch) echo "-v" ;;
  *) echo "--version" ;;
  esac
}

# Get version with timeout (handles TUI apps that might hang)
get_version() {
  local tool=$1
  local flag=$2
  # Use perl for cross-platform timeout (available on macOS)
  perl -e 'alarm 2; exec @ARGV' "$tool" "$flag" 2>/dev/null | head -1 || echo "installed"
}

for tool in "${TOOLS[@]}"; do
  echo -n "Testing $tool... "
  if command -v "$tool" >/dev/null 2>&1; then
    TOOL_PATH=$(which "$tool")
    if [[ "$TOOL_PATH" == *".nix-profile"* ]] || [[ "$TOOL_PATH" == *"/nix/store"* ]]; then
      VERSION_FLAG=$(get_version_flag "$tool")
      VERSION=$(get_version "$tool" "$VERSION_FLAG")
      echo -e "${GREEN}✅ PASS${NC} (Nix: $VERSION)"
      ((PASSED++))
    else
      echo -e "${GREEN}✅ PASS${NC} (found at $TOOL_PATH)"
      ((PASSED++))
    fi
  else
    echo -e "${RED}❌ FAIL${NC} (not found)"
    ((FAILED++))
  fi
done

echo
echo "Results: $PASSED passed, $FAILED failed"
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}🎉 All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ Some tests failed${NC}"
  exit 1
fi
