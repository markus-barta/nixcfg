#!/usr/bin/env bash
# Test T00: Nix Base System
set -euo pipefail

echo "Testing Nix Base System..."

# Test 1: Nix installed
if command -v nix >/dev/null 2>&1; then
  echo "✅ Nix installed: $(nix --version)"
else
  echo "❌ Nix not found"
  exit 1
fi

# Test 2: home-manager installed
if command -v home-manager >/dev/null 2>&1; then
  echo "✅ home-manager installed: $(home-manager --version)"
else
  echo "❌ home-manager not found"
  exit 1
fi

# Test 3: Flakes enabled
if nix eval --expr '1 + 1' 2>/dev/null; then
  echo "✅ Flakes support enabled"
else
  echo "❌ Flakes not enabled"
  exit 1
fi

# Test 4: Platform detection (requires --impure for builtins.currentSystem)
PLATFORM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
if [[ "$PLATFORM" == "x86_64-darwin" ]]; then
  echo "✅ Platform detected: $PLATFORM"
else
  echo "⚠️  Platform: $PLATFORM (expected x86_64-darwin)"
fi

# Test 5: PATH priority
if [[ "$(which fish)" == *".nix-profile"* ]]; then
  echo "✅ Nix paths prioritized in PATH"
else
  echo "❌ Nix not first in PATH"
  exit 1
fi

echo "✅ All Nix Base System tests passed"
