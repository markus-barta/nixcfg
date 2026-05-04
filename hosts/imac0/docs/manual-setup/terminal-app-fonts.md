# Configuring Nerd Fonts for macOS Terminal.app

## The Issue

macOS Terminal.app needs to be manually configured to use Nerd Fonts. Unlike Ghostty (which reads font config from a text file in `~/Library/Application Support/com.mitchellh.ghostty/config`), Terminal.app stores its settings in `~/Library/Preferences/com.apple.Terminal.plist` (NSKeyedArchiver binary format — not declarative-friendly).

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

## Solution 2: Use Ghostty (recommended; replaces the previous WezTerm option)

Ghostty (installed via Homebrew, `brew install --cask ghostty`) is the daily
terminal across the macOS fleet since 2026-05-05. Configure its font:

```bash
# Edit Ghostty config (text file, easy to manage)
mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty
cat >> ~/Library/Application\ Support/com.mitchellh.ghostty/config <<'EOF'
font-family = Hack Nerd Font Mono
font-size = 12
EOF
```

Restart Ghostty to apply.

### Benefits of Ghostty:

- ✅ GPU-accelerated, fast
- ✅ Text config file (easy to back up / version-control out-of-Nix)
- ✅ Nerd Fonts work natively (font-family pulls from `~/Library/Fonts/`)
- ✅ Zig-based, native macOS feel
- ⚠️ Currently NOT declaratively managed via Nix (config lives in the support
  dir; not in `home.nix`). Future: file an HM ticket to wire Ghostty config
  into Nix similar to how `programs.wezterm.extraConfig` worked pre-2026-05-05.

## How Fonts Are Installed

Hack Nerd Fonts are automatically installed to macOS via home-manager activation script:

```nix
# In home.nix - automatically runs on home-manager switch
home.activation.installMacOSFonts = ''
  # Symlinks all Hack Nerd Font variants to ~/Library/Fonts/
  # Makes fonts available in Font Book and Terminal.app
'';
```

After running `home-manager switch`, the fonts are available system-wide. You may need to restart the font daemon:

```bash
killall fontd
```

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

**Contrast with Ghostty**:

- Ghostty uses a **plain-text config file** (declarative-friendly, but currently
  not wired into Nix on this fleet — Homebrew install + manual config edit)
- Could be wired into Nix as a small `home.file` for ergonomics; HM ticket pending

## Recommendation

**Use Ghostty** (Homebrew install) — fast, modern, text-file config. Pre-2026-05-05 this doc recommended Nix-managed WezTerm; that path was retired during fleet-wide migration to Ghostty. Terminal.app will always require one-time manual setup per machine due to macOS plist limitations regardless of which terminal you choose as default.
