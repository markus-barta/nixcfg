# imac-27-home - macOS Development Machine

Personal macOS development machine with Nix package management.

## Quick Links

- 📖 **[Progress & History](docs/progress.md)** - Migration status & complete history
- 🛠️ **[Manual Setup Guides](docs/manual-setup/)** - One-time configuration steps
- 📚 **[Technical Reference](docs/reference/)** - Deep dives into specific features
- 📁 **[Documentation Index](docs/README.md)** - Full docs structure

---

## Current State (2025-11-15)

### 🎉 **MIGRATION 100% COMPLETE** 🎉

**Core Migration Complete**:

- ✅ All configurations declaratively managed via Nix
- ✅ Shell (Fish), Terminal (WezTerm), Prompt (Starship), Git dual identity
- ✅ Global interpreters (Node.js, Python) + project-specific versions
- ✅ Essential CLI tools (bat, btop, ripgrep, fd, fzf, etc.)
- ✅ Fonts (Hack Nerd Font) for both WezTerm and Terminal.app
- ✅ Karabiner-Elements configuration declarative

**System Integration**:

- ✅ Nix fish as default login shell
- ✅ PATH properly prioritizes Nix over Homebrew
- ✅ All Homebrew duplicates removed (git, wezterm, font-hack-nerd-font)
- ✅ Cleaned Homebrew cache (~110MB freed)

**Current Setup**:

```bash
$ which fish git node python3 starship wezterm
/Users/markus/.nix-profile/bin/fish (v4.1.2)
/Users/markus/.nix-profile/bin/git (v2.51.0) ✅
/Users/markus/.nix-profile/bin/node (v22.20.0)
/Users/markus/.nix-profile/bin/python3 (v3.13.8)
/Users/markus/.nix-profile/bin/starship
/Users/markus/.nix-profile/bin/wezterm
```

**Git Dual Identity Verified** ✅:

- Personal repos: `markus@barta.com`
- BYTEPOETS repos: `markus.barta@bytepoets.com`

**Next**: Daily usage, template for `imac-27-work`

---

## Fresh Machine Setup

To replicate this setup on a new machine (e.g., `imac-27-work`):

### 1. Clone & Apply Configuration

```bash
# Clone repository
git clone https://github.com/markus-barta/nixcfg ~/Code/nixcfg
cd ~/Code/nixcfg

# Apply home-manager configuration
home-manager switch --flake ".#markus@imac-27-home"
```

### 2. Run One-Time System Setup

```bash
# Set Nix fish as default login shell (requires sudo)
./hosts/imac-27-home/scripts/setup/setup-macos.sh

# Restart terminal
```

### 3. Manual Installations

```bash
# Karabiner-Elements (keyboard remapping)
brew install --cask karabiner-elements

# Grant "Input Monitoring" permissions in System Preferences
# Configuration is already linked via home-manager!
```

### 4. Terminal.app Fonts (Optional)

If you use Terminal.app (not just WezTerm):

- Fonts are automatically symlinked to ~/Library/Fonts/
- Refresh font cache: `killall fontd`
- Open Terminal.app → Preferences → Profiles → Text
- Select "Hack Nerd Font Mono"

See [docs/manual-setup/terminal-app-fonts.md](docs/manual-setup/terminal-app-fonts.md) for details.

---

## Directory Structure

```
hosts/imac-27-home/
├── config/                      # Configuration files
│   ├── starship.toml            # Starship prompt config
│   └── karabiner.json           # Keyboard remapping config
│
├── docs/                        # Documentation
│   ├── README.md                # Docs index
│   ├── progress.md              # Migration history & status
│   ├── manual-setup/            # One-time setup guides
│   │   ├── karabiner-setup.md
│   │   └── terminal-app-fonts.md
│   └── reference/               # Technical documentation
│       ├── karabiner-elements.md
│       ├── macos-gui-apps.md
│       └── hardware-info.md
│
├── scripts/
│   ├── setup/                   # Setup & migration scripts
│   │   ├── backup-migration.sh  # Pre-migration backup
│   │   └── setup-macos.sh       # One-time system setup
│   └── host-user/               # Daily user utilities
│       ├── flushdns.sh          # DNS cache flush
│       ├── pingt.sh             # Timestamped ping
│       └── stopAmphetamineAndSleep.sh
│
└── home.nix                     # Main home-manager configuration
```

---

## System Information

### Hardware

- **Model**: iMac 27" (2019)
- **OS**: macOS 15.7.2 (24G325)
- **Architecture**: x86_64 (Intel)

### Package Managers

- **Nix**: Primary (~20 core packages)
- **Homebrew**: Secondary (~193 remaining packages, mostly experiments/GUI apps)

### Languages & Runtimes

- **Node.js**: v22.20.0 (Nix)
- **Python**: v3.13.8 (Nix)
- **Java**: Temurin (Homebrew)

---

## Key Features

### Declarative Configuration

- **home-manager** manages dotfiles, packages, and user environment
- **devenv** provides project-specific development environments
- **Nix flakes** ensure reproducibility and version locking

### Dual Identity Git

Automatically switches Git identity based on project location:

- **Personal** (default): Markus Barta / markus@barta.com
- **Work** (~/Code/BYTEPOETS/): mba / markus.barta@bytepoets.com

### Keyboard Remapping

Karabiner-Elements configuration (declarative):

- **Caps Lock → Hyper** (Cmd+Ctrl+Opt+Shift)
- **F1-F12** as regular function keys in terminals

### Scripts Management

Essential user scripts version-controlled and symlinked to `~/Scripts/`:

- `flushdns.sh` - DNS cache flush
- `pingt.sh` - Timestamped ping (pure bash)
- `stopAmphetamineAndSleep.sh` - System sleep control

---

## Making Changes

### Update Configuration

```bash
cd ~/Code/nixcfg

# Edit configuration
vim hosts/imac-27-home/home.nix

# Apply changes
home-manager switch --flake ".#markus@imac-27-home"

# Commit to git
git add hosts/imac-27-home/home.nix
git commit -m "Update configuration"
git push
```

### Add New Script

```bash
# Create script in host-user directory
vim hosts/imac-27-home/scripts/host-user/new-script.sh
chmod +x hosts/imac-27-home/scripts/host-user/new-script.sh

# Commit to git
git add hosts/imac-27-home/scripts/host-user/new-script.sh
git commit -m "Add new-script"

# Apply changes (script automatically symlinked to ~/Scripts/)
home-manager switch --flake ".#markus@imac-27-home"
```

### Update Karabiner Mappings

```bash
# Edit configuration
vim hosts/imac-27-home/config/karabiner.json

# Commit changes
git add hosts/imac-27-home/config/karabiner.json
git commit -m "Update keyboard mappings"

# Apply changes
home-manager switch --flake ".#markus@imac-27-home"

# Reload Karabiner-Elements (if needed)
killall karabiner_console_user_server
```

---

## Troubleshooting

### Commands Not Found After Switch

Check PATH priority:

```bash
echo $PATH
# Should show ~/.nix-profile/bin first
```

Restart terminal or reload shell:

```bash
exec fish
```

### Nerd Font Icons Missing

Check font installation:

```bash
fc-list | grep "Hack Nerd"
```

Restart fontd:

```bash
killall fontd
```

### Karabiner Not Working

Check app is running and has permissions:

```bash
# System Preferences → Security & Privacy → Privacy → Input Monitoring
# Ensure "karabiner_grabber" and "Karabiner-Elements" are enabled
```

Restart Karabiner:

```bash
killall karabiner_console_user_server
```

---

## Architecture Decisions

### Why home-manager (not nix-darwin)?

- **macOS Upgrade Safety**: User-level only, no system-level conflicts
- **Lower Risk**: Failures don't affect system
- **Sufficient**: Don't need system-level management for single-user machine

### Why Hybrid (Homebrew + Nix)?

- **Nix**: Declarative for core workflow tools (~20 packages)
- **Homebrew**: Flexible for GUI apps and experiments (~193 packages)
- **Best of Both**: Reproducible core + experimental freedom

### Why Manual Steps (setup-macos.sh)?

- **Simplicity**: Two commands (add to /etc/shells, chsh) vs nix-darwin complexity
- **Safety**: No system-level automation = no system-level breakage
- **Trade-off**: One-time manual execution vs full automation

---

**For complete migration history and technical details, see [docs/progress.md](docs/progress.md)**
