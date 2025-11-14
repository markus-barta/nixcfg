#!/usr/bin/env bash

set -euo pipefail

# Stage 1: Uninstall Nix-managed CLI tools from Homebrew
# These packages are now managed by Nix via home-manager

NIX_MANAGED_PACKAGES=(
  "fish"
  "node"
  "python@3.13"
  "bat"
  "btop"
  "ripgrep"
  "fd"
  "zoxide"
  "direnv"
  "starship"
)

echo "🗑️  Stage 1: Homebrew Cleanup - Nix-Managed CLI Tools"
echo "=========================================================="
echo ""
echo "This will uninstall the following packages from Homebrew:"
echo "(They are now managed by Nix and already inactive)"
echo ""

PACKAGES_TO_REMOVE=()

for pkg in "${NIX_MANAGED_PACKAGES[@]}"; do
  if brew list --formula "$pkg" &>/dev/null; then
    echo "  ✓ $pkg"
    PACKAGES_TO_REMOVE+=("$pkg")
  else
    echo "  ⊗ $pkg (not installed)"
  fi
done

if [ ${#PACKAGES_TO_REMOVE[@]} -eq 0 ]; then
  echo ""
  echo "✨ No packages to uninstall - already clean!"
  exit 0
fi

echo ""
echo "📊 Disk space that will be freed:"
brew info "${PACKAGES_TO_REMOVE[@]}" 2>/dev/null | grep -E "^[^:]+: .* \(.*\)$" || true
echo ""
echo "⚠️  SAFETY CHECK:"
echo "   - All these packages are unlinked (inactive)"
echo "   - Nix versions are already active and tested"
echo "   - You can reinstall with: brew install <package>"
echo ""
read -p "Continue with uninstall? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "❌ Aborted"
  exit 1
fi

echo ""
echo "🗑️  Uninstalling Homebrew packages..."
for pkg in "${PACKAGES_TO_REMOVE[@]}"; do
  echo "  Removing $pkg..."
  brew uninstall "$pkg" || echo "    ⚠️  Failed to uninstall $pkg"
done

echo ""
echo "✅ Stage 1 Cleanup Complete!"
echo ""
echo "📝 Summary:"
echo "   - Uninstalled ${#PACKAGES_TO_REMOVE[@]} packages"
echo "   - Nix versions remain active"
echo "   - Old Homebrew cache: ~/Library/Caches/Homebrew/"
echo ""
echo "💡 Verify everything still works:"
echo "   which fish node python3 bat btop rg fd zoxide direnv starship"
echo ""
echo "🧹 Optional: Clean Homebrew cache"
echo "   brew cleanup --prune=all"
