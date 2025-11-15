#!/usr/bin/env bash
set -euo pipefail

# Setup Terminal.app to use Hack Nerd Font Mono declaratively
# This is part of the Nix migration but Terminal.app requires macOS-specific plist manipulation

PROFILE_NAME="Basic"

echo "🎨 Configuring Terminal.app to use Hack Nerd Font Mono..."

# Check if font is installed
if ! fc-list | grep -q "Hack Nerd Font"; then
  echo "❌ Hack Nerd Font not found. Install it via home-manager first."
  exit 1
fi

echo "✅ Hack Nerd Font found"

# Close Terminal.app if running (required for changes to take effect)
if pgrep -x "Terminal" >/dev/null; then
  echo "📝 Terminal.app is running. Changes will apply after restart."
  echo "   You can close it manually or continue (changes apply on next launch)"
  read -p "Close Terminal.app now? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    osascript -e 'quit app "Terminal"' 2>/dev/null || true
    sleep 1
  fi
fi

# Create font data for Terminal.app (NSFont archived format)
# This is a base64-encoded NSKeyedArchiver format
# Font: Hack Nerd Font Mono Regular 12pt
FONT_DATA="YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBcLDBMXGBkaHB4fICEjJCUmKCkqLC0vMDEyMzQ1Nzg5Ojs9P0BBQkRFRkdISUpMTU5QUVJTVFVXWV8QD05TRm9udFNpemVBdHRyXxAUTlNGb250TmFtZUF0dHJpYnV0ZVxOU0ZvbnRDbGFzc18QEk5TRm9udERlc2NyaXB0b3JfEBBOU0ZvbnRWaXNpYmxlTmFtZYACgBaAF4AEgAOABYAGXEhhY2sgTmVyZCBGb250IgBAKAAAAAAAANIQERIVWiRjbGFzc25hbWVYJGNsYXNzZXNWTlNGb250ohQWWE5TT2JqZWN00hAREhhaTlNGb250TmFtZaIZFlxOU0ZvbnROYW1lXxAXSGFja05lcmRGb250TW9uby1SZWd1bGFy0hARGhteTlNNdXRhYmxlQXJyYXmjGxwWV05TQXJyYXnSEBEeIF8QD05TRm9udERlc2NyaXB0b3KiIRZfEA9OU0ZvbnREZXNjcmlwdG9y0hARIiZfEBROQUtleWVkVW5hcmNoaXZlciSAB4AACAARABoAIwAtADIANwBJAEwAUQBdAGQAawBzAIAAiQCQAJsApACxALgAwgDDAMUAxwDJAMsAzQDPANEA0wDVANcA2QDbAN0A4ADyAPUA+gAAAAAAAAIBAAAAAAAAACcAAAAAAAAAAAAAAAAAAAEC"

# Get current Terminal preferences
PREFS_FILE="$HOME/Library/Preferences/com.apple.Terminal.plist"

# Backup current preferences
if [ -f "$PREFS_FILE" ]; then
  BACKUP_FILE="$PREFS_FILE.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$PREFS_FILE" "$BACKUP_FILE"
  echo "📦 Backed up Terminal preferences to: $BACKUP_FILE"
fi

# Set the font using defaults write
# Note: This sets a simple font name. For full control, we'd need to manipulate the binary plist.
defaults write com.apple.Terminal "Default Window Settings" "$PROFILE_NAME"
defaults write com.apple.Terminal "Startup Window Settings" "$PROFILE_NAME"

# Set font for the profile using PlistBuddy (more reliable than defaults for nested values)
PROFILE_KEY="Window Settings:$PROFILE_NAME"

# Check if profile exists
if ! /usr/libexec/PlistBuddy -c "Print :'$PROFILE_KEY'" "$PREFS_FILE" &>/dev/null; then
  echo "⚠️  Profile '$PROFILE_NAME' not found in Terminal preferences"
  echo "   Please open Terminal.app at least once to create default profiles"
  exit 1
fi

# Set font name (this is a simplified approach - Terminal.app uses NSArchiver format)
/usr/libexec/PlistBuddy -c "Set :'$PROFILE_KEY:Font' '$FONT_DATA'" "$PREFS_FILE" 2>/dev/null ||
  /usr/libexec/PlistBuddy -c "Add :'$PROFILE_KEY:Font' data '$FONT_DATA'" "$PREFS_FILE" 2>/dev/null ||
  {
    echo "⚠️  Could not set font data programmatically"
    echo "   This is a limitation of Terminal.app's plist format"
    echo ""
    echo "📝 Please set the font manually (one-time setup):"
    echo "   1. Open Terminal.app"
    echo "   2. Press Cmd+, (Preferences)"
    echo "   3. Go to Profiles → Text tab"
    echo "   4. Click 'Change' button next to font"
    echo "   5. Search for 'Hack Nerd' and select 'Hack Nerd Font Mono'"
    echo ""
    echo "   This only needs to be done once per machine."
    exit 1
  }

echo "✅ Terminal.app font configured!"
echo ""
echo "🔄 Restart Terminal.app for changes to take effect"
printf "   Test with: printf 'Nerd Font icons: \\\\uE0A0 \\\\uE718 \\\\uE73C \\\\uF07B \\\\uF00C\\\\n'\n"
