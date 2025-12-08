#!/usr/bin/env bash
# T07: Custom Scripts - Automated Test
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== T07: Custom Scripts Test ==="
echo

# Note: pingt is now a fish function (via uzumaki module), not a shell script
SCRIPTS=("flushdns.sh" "stopAmphetamineAndSleep.sh")

for script in "${SCRIPTS[@]}"; do
  echo -n "Test: $script exists... "
  if [[ -f "$HOME/Scripts/$script" ]]; then
    if [[ -x "$HOME/Scripts/$script" ]]; then
      echo -e "${GREEN}✅ PASS${NC} (executable)"
    else
      echo -e "${GREEN}✅ PASS${NC} (not executable)"
    fi
  else
    echo -e "${RED}❌ FAIL${NC}"
    exit 1
  fi
done

echo
echo -e "${GREEN}🎉 All tests passed!${NC}"
exit 0
