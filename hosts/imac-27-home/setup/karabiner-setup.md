# Karabiner-Elements Setup

## Installation (One-Time, Manual)

Karabiner-Elements **must** be installed via Homebrew because it:

- Requires system-level drivers (kernel extensions)
- Needs macOS system permissions
- Is not available in nixpkgs

### Install Command

```bash
brew install --cask karabiner-elements
```

## Post-Installation

1. **Grant Permissions**:
   - macOS will prompt for "Input Monitoring" permission
   - Open System Preferences → Security & Privacy → Privacy
   - Grant permissions to Karabiner-Elements and karabiner_grabber

2. **Configuration is Already Managed**:
   - ✅ Your config is already linked via home-manager
   - ✅ Located at: `~/.config/karabiner/karabiner.json` (symlink to Nix store)
   - ✅ Version-controlled in git

3. **Verify It Works**:
   - Test: Press **Caps Lock** → should act as Hyper (Cmd+Ctrl+Opt+Shift)
   - Test: Press **F1** in terminal → should be F1 (not brightness)

## Why This Hybrid Approach?

**Karabiner-Elements App**: Homebrew ✅

- System driver needs privileged access
- GUI app for manual adjustments
- Not available in Nix

**Karabiner Configuration**: Nix/home-manager ✅

- Fully declarative
- Version-controlled
- Reproducible

## Making Changes

### Method 1: Edit Declaratively (Recommended)

```bash
# 1. Edit the config file
vim ~/Code/nixcfg/hosts/imac-27-home/config/karabiner.json

# 2. Commit to git
git add hosts/imac-27-home/config/karabiner.json
git commit -m "Update Karabiner mappings"

# 3. Apply to system
home-manager switch --flake ".#markus@imac-27-home"
```

### Method 2: Use Karabiner GUI (Not Recommended)

If you use the GUI to make changes:

1. Changes go to `~/.config/karabiner/karabiner.json` (will be a **broken symlink** after switch!)
2. You need to manually copy changes back to `config/karabiner.json` in the repo
3. Then commit and re-apply

**Stick with Method 1** for a fully declarative workflow!

## Your Current Configuration

Already configured in Nix:

1. **Caps Lock → Hyper** (Cmd+Ctrl+Opt+Shift)
   - Use for powerful global shortcuts
   - Never conflicts with app shortcuts

2. **Function Keys in Terminals** (F1-F12)
   - Work as regular function keys
   - No media keys in terminal apps

3. **Device-Specific Settings**
   - Keyboard (vendor: 1133, product: 50475) ignored

## Troubleshooting

### Karabiner Not Working After Install

1. Restart Karabiner-Elements
2. Check System Preferences → Security & Privacy → Privacy
3. Ensure all Karabiner components have permissions

### Configuration Not Applied

```bash
# Karabiner needs to reload after config changes
killall karabiner_console_user_server
# Or restart Karabiner-Elements app
```

### Want to Disable Temporarily

Open Karabiner-Elements → Quit (menu bar icon)

## Keep in Homebrew

✅ **Keep**: `karabiner-elements` (cask)
❌ **Don't manage in Nix**: Configuration is declarative, app stays in Homebrew
