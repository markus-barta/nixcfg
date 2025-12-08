#!/usr/bin/env bash
# Test T01: Fish Shell
# Tests fish shell installation and uzumaki functions
set -euo pipefail

echo "Testing Fish Shell..."

# Test 1: Fish installed
if command -v fish >/dev/null 2>&1; then
  VERSION=$(fish --version)
  echo "✅ Fish installed: $VERSION"
else
  echo "❌ Fish not found"
  exit 1
fi

# Test 2: Fish from Nix
FISH_PATH=$(which fish)
if [[ "$FISH_PATH" == *".nix-profile"* ]]; then
  echo "✅ Fish from Nix: $FISH_PATH"
else
  echo "❌ Fish not from Nix: $FISH_PATH"
  exit 1
fi

# Test 3: Fish as default shell
if [[ "$SHELL" == *"fish"* ]]; then
  echo "✅ Fish is default shell"
else
  echo "⚠️  Fish not default shell: $SHELL"
fi

# Test 4: Core uzumaki functions
CORE_FUNCTIONS=(pingt sourcefish stress helpfish stasysmod hostcolors hostsecrets)
for func in "${CORE_FUNCTIONS[@]}"; do
  if fish -c "functions -q $func" 2>/dev/null; then
    echo "✅ $func function exists"
  else
    echo "❌ $func function not found"
    exit 1
  fi
done

# Test 5: brewall function exists (macOS-specific, defined in macos-common.nix)
if fish -c "functions -q brewall" 2>/dev/null; then
  echo "✅ brewall function exists"
else
  echo "⚠️  brewall function not found (optional)"
fi

# Test 6: pingt produces timestamped output
PINGT_OUTPUT=$(fish -c "pingt -c 1 127.0.0.1" 2>&1 || true)
if echo "$PINGT_OUTPUT" | grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
  echo "✅ pingt adds timestamps to output"
else
  echo "❌ pingt doesn't add timestamps"
  exit 1
fi

# Test 7: helpfish shows functions
HELPFISH_OUTPUT=$(fish -c "helpfish" 2>&1 || true)
if echo "$HELPFISH_OUTPUT" | grep -q "Functions"; then
  echo "✅ helpfish shows Functions section"
else
  echo "❌ helpfish missing Functions section"
  exit 1
fi

# Test 8: hostcolors shows host overview
HOSTCOLORS_OUTPUT=$(fish -c "hostcolors" 2>&1 || true)
if echo "$HOSTCOLORS_OUTPUT" | grep -q "CLOUD\|HOME\|WORKSTATIONS"; then
  echo "✅ hostcolors shows host categories"
else
  echo "❌ hostcolors missing host overview"
  exit 1
fi

# Test 9: Key abbreviations
if fish -c "abbr --show" 2>/dev/null | grep -q "ping.*pingt"; then
  echo "✅ ping → pingt abbreviation"
else
  echo "⚠️  ping → pingt abbreviation not set"
fi

if fish -c "abbr --show" 2>/dev/null | grep -q "tmux.*zellij"; then
  echo "✅ tmux → zellij abbreviation"
else
  echo "⚠️  tmux → zellij abbreviation not set"
fi

# Test 10: SSH shortcuts (aliases)
SSH_ALIASES=(hsb0 hsb1 hsb8 gpc0 mbpw csb0 csb1)
echo "Checking SSH shortcuts..."
for alias in "${SSH_ALIASES[@]}"; do
  if fish -c "alias" 2>/dev/null | grep -q "^$alias "; then
    echo "✅ $alias SSH shortcut exists"
  else
    echo "⚠️  $alias SSH shortcut not found (optional)"
  fi
done

echo "✅ All Fish Shell tests passed"
