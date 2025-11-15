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

## Solution 3: Script to Set Terminal.app Font (Semi-Automated)

**Note**: Due to Terminal.app using NSKeyedArchiver binary format for font data, full automation is not reliable. The script will attempt to configure it, but manual setup is recommended.

```bash
# Run the setup script
~/Code/nixcfg/hosts/imac-27-home/setup/setup-terminal-app-font.sh
```

This script will:

- ✅ Verify Hack Nerd Font is installed
- ✅ Backup current Terminal.app preferences
- ⚠️ Attempt to set font (may not work due to plist format)
- 📝 Provide manual instructions if needed

**Why this is not fully declarative**: Terminal.app stores font information in a proprietary NSKeyedArchiver binary format in its plist file. Unlike text-based configs, this can't be reliably generated programmatically. This is a macOS limitation, not a Nix limitation.

## Verification

After configuring the font, test it:

```bash
printf 'Nerd Font icons: \uE0A0 \uE718 \uE73C \uF07B \uF00C\n'
```

You should see: Git branch , Node.js , Python , Folder , Check

## Can This Be Done Declaratively?

**Short answer**: No, not fully.

**Why**:

- Terminal.app stores settings in `~/Library/Preferences/com.apple.Terminal.plist`
- Font data is stored in **NSKeyedArchiver binary format** (not human-readable)
- This format can't be reliably generated programmatically
- Apple doesn't provide CLI tools to manipulate this data

**Contrast with WezTerm**:

- WezTerm uses **Lua config files** (declarative, text-based)
- Can be fully managed by Nix via `home.nix`
- Works identically across all machines
- No manual setup required

## Recommendation

**Use WezTerm** (already configured) - it's the only fully declarative solution. Terminal.app will always require one-time manual setup per machine due to macOS limitations.
