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

PACKAGES_TO_UNLINK=()

for pkg in "${NIX_MANAGED_PACKAGES[@]}"; do
  if brew list --formula "$pkg" &>/dev/null; then
    if brew ls --verbose "$pkg" 2>/dev/null | grep -q "^/usr/local/bin/\|^/opt/homebrew/bin/"; then
      echo "  ✓ $pkg (currently linked)"
      PACKAGES_TO_UNLINK+=("$pkg")
    else
      echo "  ℹ $pkg (installed but not linked)"
    fi
  else
    echo "  ⊗ $pkg (not installed via Homebrew)"
  fi
done

echo ""

if [ ${#PACKAGES_TO_UNLINK[@]} -eq 0 ]; then
  echo "✨ No Homebrew packages to unlink - you're all set!"
  exit 0
fi

echo "📦 Will unlink ${#PACKAGES_TO_UNLINK[@]} packages: ${PACKAGES_TO_UNLINK[*]}"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "❌ Aborted"
  exit 1
fi

echo ""
echo "🔧 Unlinking Homebrew packages..."
for pkg in "${PACKAGES_TO_UNLINK[@]}"; do
  echo "  Unlinking $pkg..."
  brew unlink "$pkg" || echo "    ⚠ Failed to unlink $pkg (might already be unlinked)"
done

echo ""
echo "✅ Done! Homebrew duplicates are now disabled."
echo ""
echo "💡 To re-enable them later, run:"
echo "   ./enable-homebrew-duplicates.sh"
echo ""
echo "🧪 Verify your Nix packages are working:"
echo "   which fish node python3 bat btop rg fd fzf zoxide direnv starship"
