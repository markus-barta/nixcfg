#!/usr/bin/env bash

set -euo pipefail

# Packages that are now managed by Nix
NIX_MANAGED_PACKAGES=(
  "fish"
  "node"
  "python@3.13"
  "bat"
  "btop"
  "ripgrep"
  "fd"
  "fzf"
  "zoxide"
  "direnv"
  "starship"
)

echo "🔍 Checking which Nix-managed packages are installed via Homebrew..."
echo ""

PACKAGES_TO_LINK=()

for pkg in "${NIX_MANAGED_PACKAGES[@]}"; do
  if brew list --formula "$pkg" &>/dev/null; then
    if ! brew ls --verbose "$pkg" 2>/dev/null | grep -q "^/usr/local/bin/\|^/opt/homebrew/bin/"; then
      echo "  ✓ $pkg (currently unlinked)"
      PACKAGES_TO_LINK+=("$pkg")
    else
      echo "  ℹ $pkg (already linked)"
    fi
  else
    echo "  ⊗ $pkg (not installed via Homebrew)"
  fi
done

echo ""

if [ ${#PACKAGES_TO_LINK[@]} -eq 0 ]; then
  echo "✨ No Homebrew packages to link - they're already enabled!"
  exit 0
fi

echo "📦 Will link ${#PACKAGES_TO_LINK[@]} packages: ${PACKAGES_TO_LINK[*]}"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "❌ Aborted"
  exit 1
fi

echo ""
echo "🔧 Linking Homebrew packages..."
for pkg in "${PACKAGES_TO_LINK[@]}"; do
  echo "  Linking $pkg..."
  brew link "$pkg" || echo "    ⚠ Failed to link $pkg"
done

echo ""
echo "✅ Done! Homebrew packages are now re-enabled."
echo ""
echo "🧪 Verify Homebrew packages are working:"
echo "   which fish node python3 bat btop rg fd fzf zoxide direnv starship"
