#!/usr/bin/env bash
# Test T01: Fish Shell
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

# Test 4: Custom functions exist
if fish -c "functions brewall sourceenv sourcefish" >/dev/null 2>&1; then
  echo "✅ Custom functions configured"
else
  echo "❌ Custom functions not found"
  exit 1
fi

echo "✅ All Fish Shell tests passed"
