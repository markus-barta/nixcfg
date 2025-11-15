# macOS GUI Applications Management

## The Elegant Nix Solution

home-manager automatically manages macOS GUI applications through a declarative approach:

### How It Works

1. **Automatic App Linking**: When you enable a GUI program in `home.nix`, home-manager automatically:
   - Detects `.app` bundles in the Nix package
   - Creates symlinks in `~/Applications/Home Manager Apps/`
   - Makes them available to Spotlight, Launchpad, and Finder

2. **Declarative Configuration**: Simply enable the program in your `home.nix`:

```nix
programs.wezterm = {
  enable = true;
  # ... your config
};
```

3. **Automatic Updates**: When you `home-manager switch`:
   - Old symlinks are removed
   - New symlinks point to updated app versions
   - No manual intervention needed

### What You See

```
~/Applications/
├── Home Manager Apps/          # ← Created by home-manager
│   └── WezTerm.app -> /nix/store/.../WezTerm.app
```

### Making Nix Apps Easily Accessible

#### Option 1: Use Spotlight (⌘+Space)

- **Instant**: Type "WezTerm" in Spotlight
- **Works immediately**: Spotlight indexes `~/Applications/Home Manager Apps/`
- **Recommendation**: This is the macOS-native way

#### Option 2: Symlink to Main Applications Folder

For apps you want directly in `~/Applications/`:

```nix
# In home.nix
home.activation.linkMacOSApps = lib.hm.dag.entryAfter ["writeBoundary"] ''
  echo "Linking macOS applications..."

  # Create directory if it doesn't exist
  mkdir -p ~/Applications

  # Link important apps to main Applications folder
  apps=(
    "WezTerm.app"
    # Add more apps here as needed
  )

  for app in "''${apps[@]}"; do
    source="$HOME/Applications/Home Manager Apps/$app"
    target="$HOME/Applications/$app"

    if [ -e "$source" ]; then
      # Remove old symlink or Homebrew version
      if [ -L "$target" ] || [ -e "$target" ]; then
        echo "  Removing old $app..."
        rm -rf "$target"
      fi

      # Create new symlink
      echo "  Linking $app"
      ln -sf "$source" "$target"
    fi
  done

  echo "✅ macOS applications linked"
'';
```

#### Option 3: Add to Dock Declaratively

Use `dockutil` (requires additional setup):

```nix
home.packages = [ pkgs.dockutil ];

home.activation.configureDock = lib.hm.dag.entryAfter ["linkMacOSApps"] ''
  echo "Configuring Dock..."

  # Remove old Homebrew WezTerm from Dock
  /Users/markus/.nix-profile/bin/dockutil --remove "WezTerm" --no-restart 2>/dev/null || true

  # Add Nix WezTerm to Dock
  /Users/markus/.nix-profile/bin/dockutil --add "$HOME/Applications/WezTerm.app" --no-restart

  killall Dock
  echo "✅ Dock configured"
'';
```

### Fixing Broken Dock Icons

When you uninstall a Homebrew app, the Dock icon breaks. **Two elegant solutions**:

#### Quick Fix (Manual, One-Time)

1. Remove broken icon from Dock: Right-click → Options → Remove from Dock
2. Open Spotlight (⌘+Space)
3. Type "WezTerm"
4. Right-click on result → Options → Keep in Dock

#### Automated Fix (Declarative)

Use the `home.activation.linkMacOSApps` script above - it symlinks to `~/Applications/` where macOS expects apps.

### Best Practice Recommendation

**For most users (Recommended):**

- Use **Spotlight** (⌘+Space) to launch Nix apps
- No additional configuration needed
- Works perfectly out of the box
- Most Mac-native approach

**For power users (Optional):**

- Add `home.activation.linkMacOSApps` to symlink important apps to `~/Applications/`
- Gives you Finder access and easier Dock management
- Requires one-time Dock icon replacement

### Managing Multiple GUI Apps

As you add more Nix GUI apps, they'll automatically appear in `Home Manager Apps/`:

```nix
programs.wezterm.enable = true;        # → WezTerm.app
# programs.alacritty.enable = true;    # → Alacritty.app (if you add it)
# programs.firefox.enable = true;       # → Firefox.app (if you add it)
```

All automatically managed, versioned, and reproducible! 🎉

### Advantages Over Homebrew Cask

✅ **Declarative**: Apps defined in `home.nix`, not imperative `brew install`  
✅ **Version-controlled**: App versions locked in `flake.lock`  
✅ **Reproducible**: Same apps on every machine from git  
✅ **Automatic updates**: `home-manager switch` updates everything  
✅ **Rollback**: `home-manager generations` lets you rollback apps  
✅ **No manual linking**: home-manager handles all symlinks automatically

### Current Setup

Your WezTerm is **already working**:

- Installed via Nix
- Linked to `~/Applications/Home Manager Apps/WezTerm.app`
- Available in Spotlight
- Just need to fix Dock icon (see "Fixing Broken Dock Icons" above)
