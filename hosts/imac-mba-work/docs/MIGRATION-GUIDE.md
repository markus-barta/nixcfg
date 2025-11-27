# imac-mba-work Migration Guide

**Machine**: Work iMac (BYTEPOETS)  
**Hostname**: imac-mba-work  
**Date**: 2025-11-27  
**Status**: 🔄 In Progress

---

## Pre-Migration Checklist

### ✅ Completed Steps

- [x] Nix installed (v2.32.4)
- [x] Flakes enabled (`~/.config/nix/nix.conf`)
- [x] Repository cloned (`~/Code/nixcfg`)
- [x] Backup created (`~/Desktop/pre-nix-backup-20251127-142146/`)

### 📋 Backup Contents

```
~/Desktop/pre-nix-backup-20251127-142146/
├── .gitconfig           # Git configuration
├── .gitignore_global    # Global gitignore
├── .wezterm.lua         # WezTerm config
├── fish/                # Fish shell config
├── karabiner/           # Keyboard remapping
└── starship.toml        # Prompt config
```

---

## Package Migration Analysis

### Packages to UNINSTALL from Homebrew (Conflicts)

These are in Homebrew AND will be installed by Nix:

| Package   | Homebrew | Nix | Action |
|-----------|----------|-----|--------|
| fish      | ✅       | ✅  | `brew uninstall fish` |
| starship  | ✅       | ✅  | `brew uninstall starship` |
| zoxide    | ✅       | ✅  | `brew uninstall zoxide` |
| wezterm   | ✅ cask  | ✅  | `brew uninstall --cask wezterm` |
| nano      | ✅       | ✅  | `brew uninstall nano` |
| gh        | ✅       | ✅  | `brew uninstall gh` |
| jq        | ✅       | ✅  | `brew uninstall jq` |
| git       | ✅       | ✅  | `brew uninstall git` |
| node      | ✅       | ✅  | `brew uninstall node` |
| btop      | ✅       | ✅  | `brew uninstall btop` |
| midnight-commander | ✅ | ✅ | `brew uninstall midnight-commander` |
| direnv    | ✅       | ✅  | `brew uninstall direnv` |
| font-hack-nerd-font | ✅ cask | ✅ | `brew uninstall --cask font-hack-nerd-font` |

### Packages to KEEP in Homebrew

These are NOT in Nix config or work better via Homebrew:

| Package | Reason |
|---------|--------|
| ffmpeg | Complex multimedia, many dependencies |
| tesseract | OCR, complex dependencies |
| docker, docker-compose | Docker Desktop integration |
| openjdk | Java runtime |
| tmux | Not using (zellij replaces it) - can remove |
| htop | btop replaces it - can remove |
| topgrade | System updater - evaluate if needed |
| go-jira | Jira CLI - evaluate if needed |
| cloc | Code counter - evaluate if needed |
| blueutil | Bluetooth CLI - macOS specific |
| defaultbrowser | macOS specific |
| watch | Simple utility - keep or migrate |

### Homebrew Casks to KEEP

| Cask | Reason |
|------|--------|
| ghostty | Alternative terminal (keep for now) |
| hammerspoon | macOS automation |
| macdown | Markdown editor |
| zed | Code editor |

### Packages Nix Will Install (Not in Homebrew)

These are in the Nix config but not currently installed:

| Package | Purpose |
|---------|---------|
| just | Command runner |
| lazygit | Git TUI |
| tree | Directory viewer |
| pv | Pipe viewer |
| tealdeer | tldr pages |
| fswatch | File watcher |
| zellij | Terminal multiplexer |
| netcat | Network utility |
| wakeonlan | WoL utility |
| websocat | WebSocket client |
| lynx | Text browser |
| html2text | HTML converter |
| restic | Backup |
| rage | Encryption |
| rsync | Modern rsync |
| wget | Downloader |
| bat | Better cat |
| ripgrep | Fast grep |
| fd | Fast find |
| fzf | Fuzzy finder |
| prettier | Code formatter |
| nmap | Network scanner |
| python3 | Python interpreter |

---

## Migration Steps

### Step 1: Uninstall Conflicting Homebrew Packages

```bash
# Core conflicts - MUST uninstall
brew uninstall fish
brew uninstall starship
brew uninstall zoxide
brew uninstall nano
brew uninstall gh
brew uninstall jq
brew uninstall git
brew uninstall node
brew uninstall btop
brew uninstall midnight-commander
brew uninstall direnv
brew uninstall --cask wezterm
brew uninstall --cask font-hack-nerd-font

# Optional cleanup (replacements)
brew uninstall htop          # btop replaces
brew uninstall tmux          # zellij replaces

# Clean up orphaned dependencies
brew autoremove
```

**⚠️ Warning**: After uninstalling fish, your shell will temporarily change to zsh or bash.

### Step 2: Apply Home Manager Configuration

```bash
cd ~/Code/nixcfg
nix run home-manager -- switch --flake ".#markus@imac-mba-work"
```

This will install:
- Fish shell + all config
- Starship prompt
- WezTerm terminal
- Git with work identity
- All CLI tools listed above
- Hack Nerd Font
- Karabiner config

### Step 3: Set Fish as Default Shell

```bash
# Add Nix fish to allowed shells
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells

# Set as default
chsh -s ~/.nix-profile/bin/fish

# Restart terminal
```

### Step 4: Verify Installation

```bash
# Check all tools come from Nix
which fish starship git node python3 bat btop
# Should all show: /Users/markus/.nix-profile/bin/...

# Check fish version
fish --version

# Check starship
starship --version

# Check PATH priority
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

### Step 5: Install Karabiner-Elements (Optional)

```bash
brew install --cask karabiner-elements

# Grant permissions:
# System Preferences → Security & Privacy → Privacy → Input Monitoring
# Enable "karabiner_grabber" and "Karabiner-Elements"
```

---

## Post-Migration Cleanup

### Evaluate Remaining Homebrew Packages

After migration, review what's left:

```bash
brew list --formula
brew list --cask
```

Consider removing:
- `tmux` (using zellij)
- `htop` (using btop)
- `topgrade` (if not using)
- `go-jira` (if not using)

### Homebrew Dependencies

Many packages in `brew list` are auto-dependencies (libpng, freetype, etc.). They'll be removed automatically when parent packages are uninstalled:

```bash
brew autoremove
```

---

## Rollback Plan

If something goes wrong:

### Restore Configs

```bash
BACKUP=~/Desktop/pre-nix-backup-20251127-142146

# Restore fish
cp -r "$BACKUP/fish" ~/.config/

# Restore starship
cp "$BACKUP/starship.toml" ~/.config/

# Restore wezterm
cp "$BACKUP/.wezterm.lua" ~/

# Restore git
cp "$BACKUP/.gitconfig" ~/
cp "$BACKUP/.gitignore_global" ~/
```

### Reinstall Homebrew Packages

```bash
brew install fish starship zoxide nano gh jq git node btop midnight-commander direnv
brew install --cask wezterm font-hack-nerd-font
```

### Revert Shell

```bash
chsh -s /usr/local/bin/fish  # or /bin/zsh
```

---

## Differences from imac0 (Home)

| Feature | imac0 (Home) | imac-mba-work (Work) |
|---------|--------------|----------------------|
| Git default | Personal (markus@barta.com) | Work (markus.barta@bytepoets.com) |
| Git includes | Work for ~/Code/BYTEPOETS/ | Personal for ~/Code/nixcfg/ |
| esptool | ✅ Installed | ❌ Not needed |
| stopAmphetamineAndSleep.sh | ✅ | ❌ |

---

## Reference: What Nix Manages

After migration, these are declaratively managed:

### From `modules/shared/macos-common.nix`

- Fish shell (config, functions, aliases, abbreviations)
- WezTerm terminal
- Starship prompt
- Common packages (nodejs, python3, bat, ripgrep, fd, fzf, etc.)
- Hack Nerd Font
- Nano config

### From `hosts/imac-mba-work/home.nix`

- Git config (work identity default)
- Karabiner config
- Host-specific scripts
- agenix (secrets management)

### From `modules/shared/starship.toml`

- Prompt layout and styling
- Git integration
- Language indicators

---

## Timeline

- **2025-11-27 14:00**: Started migration
- **2025-11-27 14:21**: Backup created
- **2025-11-27 14:XX**: Homebrew cleanup (pending)
- **2025-11-27 14:XX**: Home Manager applied (pending)
- **2025-11-27 14:XX**: Verification (pending)

---

**Next Step**: Run the Homebrew uninstall commands in Step 1, then apply Home Manager.

