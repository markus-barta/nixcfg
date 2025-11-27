# imac-mba-work - Work iMac (BYTEPOETS)

Work macOS development machine with Nix package management.

---

## Current State (2025-11-27)

### 🚀 **NEW HOST - Initial Setup**

**Core Configuration**:

- ✅ Fish shell (shared config from `modules/shared/macos-common.nix`)
- ✅ Starship prompt (shared config from `modules/shared/starship.toml`)
- ✅ WezTerm terminal (shared config)
- ✅ Git with work identity (BYTEPOETS default)
- ✅ CLI development tools
- ✅ Karabiner-Elements keyboard remapping

**Git Identity**:

- **Default (Work)**: mba / markus.barta@bytepoets.com
- **Personal** (~/Code/personal/, ~/Code/nixcfg/): Markus Barta / markus@barta.com

---

## Fresh Machine Setup

### 1. Install Nix

```bash
# Install Nix (multi-user)
sh <(curl -L https://nixos.org/nix/install)

# Restart terminal, then enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### 2. Clone & Apply Configuration

```bash
# Clone repository
git clone https://github.com/markus-barta/nixcfg ~/Code/nixcfg
cd ~/Code/nixcfg

# Install home-manager
nix run home-manager -- switch --flake ".#markus@imac-mba-work"
```

### 3. Set Fish as Default Shell

```bash
# Add Nix fish to allowed shells
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells

# Set as default login shell
chsh -s ~/.nix-profile/bin/fish

# Restart terminal
```

### 4. Manual Installations

```bash
# Karabiner-Elements (keyboard remapping)
brew install --cask karabiner-elements

# Grant "Input Monitoring" permissions in System Preferences
# Configuration is already linked via home-manager!
```

---

## Directory Structure

```
hosts/imac-mba-work/
├── config/                      # Configuration files
│   └── karabiner.json           # Keyboard remapping config (host-specific)
│
├── scripts/
│   ├── setup/                   # Setup scripts
│   └── host-user/               # Daily user utilities
│
└── home.nix                     # Main home-manager configuration
```

## Shared Configuration

This host uses shared configs from `modules/shared/`:

```
modules/shared/
├── fish-config.nix              # Fish aliases & abbreviations (all systems)
├── macos-common.nix             # macOS fish, wezterm, packages (all Macs)
└── starship.toml                # Starship prompt (all Macs)
```

---

## System Information

### Hardware

- **Model**: iMac (Work)
- **Hostname**: imac-mba-work (company policy)
- **OS**: macOS
- **Architecture**: x86_64 (Intel)

### Package Managers

- **Nix**: Primary (declarative packages)
- **Homebrew**: Secondary (GUI apps, system integration)

---

## Key Features

### Declarative Configuration

- **home-manager** manages dotfiles, packages, and user environment
- **Shared configs** in `modules/shared/` for DRY principle
- **Nix flakes** ensure reproducibility and version locking

### Work-First Git Identity

Automatically switches Git identity based on project location:

- **Work** (default): mba / markus.barta@bytepoets.com
- **Personal** (~/Code/personal/, ~/Code/nixcfg/): Markus Barta / markus@barta.com

### Keyboard Remapping

Karabiner-Elements configuration (declarative):

- **Caps Lock → Hyper** (Cmd+Ctrl+Opt+Shift)
- **F1-F12** as regular function keys in terminals

---

## Making Changes

### Update Configuration

```bash
cd ~/Code/nixcfg

# Edit configuration
vim hosts/imac-mba-work/home.nix

# Apply changes
home-manager switch --flake ".#markus@imac-mba-work"

# Commit to git
git add hosts/imac-mba-work/
git commit -m "Update imac-mba-work configuration"
git push
```

### Update Shared Config (affects all Macs)

```bash
# Edit shared config
vim modules/shared/macos-common.nix

# Apply to this machine
home-manager switch --flake ".#markus@imac-mba-work"

# Apply to home machine (when there)
home-manager switch --flake ".#markus@imac0"
```

---

## Differences from imac0 (Home)

| Feature            | imac0 (Home)                | imac-mba-work (Work)        |
| ------------------ | --------------------------- | --------------------------- |
| **Git Default**    | Personal identity           | Work identity (BYTEPOETS)   |
| **Git Includes**   | Work for ~/Code/BYTEPOETS/  | Personal for ~/Code/nixcfg/ |
| **esptool**        | ✅ Installed                | ❌ Not needed               |

**Shared between both**:
- Fish shell config
- Starship prompt
- WezTerm terminal
- CLI tools
- Karabiner keyboard remapping

---

## Related Documentation

- [imac0 README](../imac0/README.md) - Home iMac configuration
- [Main Repository README](../../README.md) - Repository overview
- [Hosts README](../README.md) - All hosts documentation
