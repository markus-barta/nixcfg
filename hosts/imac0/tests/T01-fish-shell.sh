#!/usr/bin/env bash
# Test T01: Fish Shell
# Tests fish shell installation and uzumaki functions (pingt, stress, helpfish, etc.)
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

# Test 4: Custom functions exist (base)
if fish -c "functions brewall sourceenv sourcefish" >/dev/null 2>&1; then
  echo "✅ Base custom functions configured (brewall, sourceenv, sourcefish)"
else
  echo "❌ Base custom functions not found"
  exit 1
fi

# Test 5: Uzumaki functions exist (pingt, stress, helpfish)
if fish -c "functions -q pingt" 2>/dev/null; then
  echo "✅ pingt function exists"
else
  echo "❌ pingt function not found"
  exit 1
fi

if fish -c "functions -q stress" 2>/dev/null; then
  echo "✅ stress function exists"
else
  echo "❌ stress function not found"
  exit 1
fi

if fish -c "functions -q helpfish" 2>/dev/null; then
  echo "✅ helpfish function exists"
else
  echo "❌ helpfish function not found"
  exit 1
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

# Test 8: Key abbreviations
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

echo "✅ All Fish Shell tests passed"
