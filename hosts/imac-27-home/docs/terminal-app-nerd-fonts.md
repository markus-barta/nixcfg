# Configuring Nerd Fonts for macOS Terminal.app

## The Issue

macOS Terminal.app needs to be manually configured to use Nerd Fonts. Unlike WezTerm (which is managed by Nix and already configured), Terminal.app stores its settings in `~/Library/Preferences/com.apple.Terminal.plist`.

## Solution 1: Configure Terminal.app Manually (Recommended for Terminal.app users)

1. **Open Terminal.app**
2. **Go to Preferences** (Cmd+,)
3. **Select your profile** (e.g., "Basic" or create a new one)
4. **Click the "Text" tab**
5. **Click "Change" button next to the font**
6. **Search for "Hack Nerd"** in the font picker
7. **Select "Hack Nerd Font Mono"** (or "Hack Nerd Font")
8. **Set size** to 12-14pt
9. **Close preferences**

The Nerd Font icons should now render correctly!

## Solution 2: Use Nix-Managed WezTerm (Already Configured!)

Your WezTerm is already configured with Hack Nerd Font via Nix:

```bash
# Launch WezTerm from Nix
wezterm-gui start
```

Or make WezTerm your default terminal (it's already configured in your home.nix).

### Benefits of WezTerm:

- ✅ Already configured via Nix (declarative)
- ✅ Nerd Fonts work out of the box
- ✅ Better performance
- ✅ GPU-accelerated
- ✅ More features (splits, tabs, etc.)

## Solution 3: Script to Set Terminal.app Font (Automated)

Create a one-time setup script:

```bash
#!/usr/bin/env bash
# Set Terminal.app to use Hack Nerd Font

# This requires Terminal.app to be closed
osascript -e 'quit app "Terminal"'

# Wait a moment
sleep 1

# Set the font for the Basic profile
defaults write com.apple.Terminal "Default Window Settings" "Basic"
defaults write com.apple.Terminal "Startup Window Settings" "Basic"

# Note: Font settings are complex in Terminal.app's plist format
# Manual configuration through the GUI is more reliable

echo "Please open Terminal.app and manually set the font to 'Hack Nerd Font Mono'"
echo "Go to: Terminal > Preferences > Profiles > Text > Change Font"
```

## Verification

After configuring the font, test it:

```bash
printf 'Nerd Font icons: \uE0A0 \uE718 \uE73C \uF07B \uF00C\n'
```

You should see: Git branch , Node.js , Python , Folder , Check

## Recommendation

**Use WezTerm** - it's already fully configured via your Nix setup and will work consistently across all machines where you deploy your config. Terminal.app requires manual setup on each machine.
