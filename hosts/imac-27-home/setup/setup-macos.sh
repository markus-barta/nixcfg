#!/bin/bash
# One-time macOS system setup after home-manager activation
# Run this AFTER: home-manager switch --flake .#markus@imac-27-home
#
# Purpose: Configures system-level settings that home-manager cannot manage
# - Adds Nix fish to /etc/shells (requires sudo)
# - Changes default shell to Nix fish
#
# Why not nix-darwin: Safer for macOS upgrades, simpler, sufficient for our use case

set -e # Exit on error

echo "🔧 Setting up Nix fish as macOS login shell..."
echo ""

# 1. Add fish to /etc/shells if not already present
NIX_FISH="$HOME/.nix-profile/bin/fish"

if [ ! -f "$NIX_FISH" ]; then
  echo "❌ Error: Nix fish not found at $NIX_FISH"
  echo "   Please run 'home-manager switch' first."
  exit 1
fi

if ! grep -q "$NIX_FISH" /etc/shells; then
  echo "Adding $NIX_FISH to /etc/shells (requires sudo)..."
  echo "$NIX_FISH" | sudo tee -a /etc/shells >/dev/null
  echo "✅ Added fish to /etc/shells"
else
  echo "✅ Fish already in /etc/shells"
fi

echo ""

# 2. Change default shell to Nix fish
CURRENT_SHELL=$(dscl . -read ~/ UserShell | awk '{print $2}')
if [ "$CURRENT_SHELL" != "$NIX_FISH" ]; then
  echo "Changing default shell to Nix fish..."
  chsh -s "$NIX_FISH"
  echo "✅ Changed default shell"
else
  echo "✅ Default shell already set to Nix fish"
fi

echo ""
echo "🎉 Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Restart your terminal (or run: exec fish)"
echo "  2. Verify: echo \$SHELL  # Should show $NIX_FISH"
echo "  3. Test: which fish      # Should show Nix path"
echo "  4. After verification, you can remove Homebrew fish: brew uninstall fish"
echo ""
