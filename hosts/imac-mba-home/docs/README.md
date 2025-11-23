# imac-mba-home - Development Workstation

**iMac 27" 2019** (Intel i9) running macOS with Nix/home-manager for declarative configuration management.

---

## Quick Reference

| Item                | Value                                |
| ------------------- | ------------------------------------ |
| **Hostname**        | `imac-mba-home`                      |
| **Model**           | iMac 27" 2019 (iMac19,1)             |
| **CPU**             | Intel Core i9 8-core @ 3.6GHz        |
| **RAM**             | 16 GB                                |
| **Display**         | Retina 5K (5120 x 2880)              |
| **Graphics**        | Radeon Pro Vega 48 (8 GB VRAM)       |
| **Storage**         | 1 TB Apple SSD (APFS)                |
| **OS**              | macOS Sequoia 15.7.2                 |
| **Architecture**    | x86_64-darwin (Intel)                |
| **User**            | `markus` (Markus Barta)              |
| **Management**      | home-manager (NOT nix-darwin)        |
| **Shell**           | Fish v4.1.2 (Nix)                    |
| **Terminal**        | WezTerm (Nix)                        |
| **Config Location** | `~/Code/nixcfg/hosts/imac-mba-home/` |

---

## Features

| ID  | Component            | Description                                       | Status |
| --- | -------------------- | ------------------------------------------------- | ------ |
| F01 | Fish Shell           | Modern interactive shell with custom functions    | ✅     |
| F02 | Starship Prompt      | Cross-shell prompt with git & language indicators | ✅     |
| F03 | WezTerm Terminal     | GPU-accelerated terminal with Nerd Fonts          | ✅     |
| F04 | Git Dual Identity    | Auto-switch between personal & work identities    | ✅     |
| F05 | Node.js (LTS)        | Global Node.js v22.20.0 + project-specific        | ✅     |
| F06 | Python               | Global Python v3.13.8 + project-specific          | ✅     |
| F07 | direnv + nix-direnv  | Automatic environment loading for projects        | ✅     |
| F08 | Hack Nerd Font       | Nerd Font for terminals & system-wide             | ✅     |
| F09 | CLI Tools (45+)      | bat, btop, ripgrep, fd, fzf, zoxide, etc.         | ✅     |
| F10 | Karabiner-Elements   | Caps Lock → Hyper, F1-F12 in terminals            | ✅     |
| F11 | macOS GUI Apps (Nix) | WezTerm managed via home-manager                  | ✅     |
| F12 | Custom Scripts       | flushdns, pingt, stopAmphetamineAndSleep          | ✅     |
| F13 | Homebrew Cleanup     | Reduced from 167 → 127 formulae (~700MB freed)    | ✅     |
| F14 | Platform Detection   | Single devenv.nix for macOS/Linux projects        | ✅     |

---

## Current Status

✅ **Migration Complete** (November 15, 2025)

- **Management**: home-manager (user-level only, no nix-darwin)
- **Shell**: Nix Fish as default login shell
- **PATH**: Correctly prioritizes Nix over Homebrew
- **Packages**: 45+ packages migrated to Nix
- **Homebrew**: Reduced to 127 formulae (GUI apps + complex multimedia)
- **Configuration**: 100% declarative via `home.nix`
- **Status**: Production-ready, daily driver

---

## Table of Contents

1. [Configuration Management](#configuration-management)
2. [Hardware Specifications](#hardware-specifications)
3. [Software Environment](#software-environment)
4. [Installed Packages](#installed-packages)
5. [Git Dual Identity](#git-dual-identity)
6. [Karabiner-Elements](#karabiner-elements)
7. [Custom Scripts](#custom-scripts)
8. [System Management](#system-management)
9. [Troubleshooting](#troubleshooting)
10. [Migration History](#migration-history)

---

## Configuration Management

### Applying Configuration Changes

```bash
# Navigate to repository
cd ~/Code/nixcfg

# Apply home-manager configuration
home-manager switch --flake .#markus@imac-mba-home

# Or use the shortcut (if in devenv shell)
just home-switch
```

### Viewing Generations

```bash
# List all generations
home-manager generations

# Rollback to previous generation
home-manager switch --rollback

# Switch to specific generation
home-manager switch --switch-generation 42
```

### Editing Configuration

```bash
# Main configuration file
vim ~/Code/nixcfg/hosts/imac-mba-home/home.nix

# Starship prompt config
vim ~/Code/nixcfg/hosts/imac-mba-home/config/starship.toml

# Karabiner keyboard config
vim ~/Code/nixcfg/hosts/imac-mba-home/config/karabiner.json
```

---

## Hardware Specifications

### System Details

- **Model**: iMac 27" 2019 (iMac19,1)
- **CPU**: Intel Core i9 8-core @ 3.6GHz
  - 8 cores (Hyper-Threading enabled)
  - L2 Cache: 256 KB per core
  - L3 Cache: 16 MB
- **RAM**: 16 GB DDR4
- **Storage**: Apple SSD SM1024L
  - **Type**: NVMe SSD
  - **Capacity**: 1 TB (796 GB usable)
  - **Interface**: PCI-Express
  - **File System**: APFS
  - **Nix Store**: Separate APFS volume (disk1s7)
- **Display**: Built-In Retina LCD
  - **Resolution**: 5K (5120 x 2880)
  - **Size**: 27-inch
  - **Color Depth**: 30-bit (ARGB2101010)
- **Graphics**: Radeon Pro Vega 48
  - **VRAM**: 8 GB
  - **Bus**: PCIe x16
  - **Metal Support**: Metal 3

### Software

- **OS**: macOS Sequoia 15.7.2 (Build 24G325)
- **Architecture**: x86_64-darwin (Intel)
- **Xcode CLI Tools**: Version 2410
- **Nix**: Multi-user installation
- **home-manager**: Flake-based

---

## Software Environment

### Shell & Terminal

- **Shell**: Fish v4.1.2 (from Nix)
- **Terminal**: WezTerm (from Nix)
- **Prompt**: Starship v1.23.0
- **Font**: Hack Nerd Font (system-wide)

### Development Tools

- **Node.js**: v22.20.0 LTS (global + project-specific)
- **Python**: v3.13.8 (global + project-specific)
- **Git**: v2.51.0 (with dual identity support)
- **direnv**: v2.37.1 (with nix-direnv)

### Key Features

**Fish Shell Custom Functions:**

- `brewall` - Upgrade Homebrew packages
- `cd` - Enhanced with auto-ls after directory change
- `sudo` - Pass aliases and functions through sudo
- `sourceenv` - Load .env files
- `sourcefish` - Reload Fish configuration
- `pingt` - Timestamped ping (uses custom script)

**Fish Shell Abbreviations:**

- `flushdns` - Flush DNS cache (macOS)
- `qc0`, `qc1`, `qc24`, `qc99` - Quick SSH to servers with zellij attach

**Shell Aliases:**

- `mc` - Midnight Commander with solarized skin
- `lg` - lazygit
- `ping` - Force macOS native ping (Nix inetutils has bugs)
- `traceroute`, `netstat` - Native macOS network tools

---

## Installed Packages

### Global CLI Tools (from Nix)

**Development:**

- `gh` - GitHub CLI
- `jq` - JSON processor
- `just` - Command runner
- `lazygit` - Git TUI
- `prettier` - Code formatter

**File Management:**

- `bat` - Cat with syntax highlighting
- `tree` - Directory tree viewer
- `fd` - Find replacement
- `ripgrep` - Fast grep
- `fzf` - Fuzzy finder
- `mc` - Midnight Commander
- `pv` - Progress viewer
- `tealdeer` - tldr pages
- `fswatch` - File watcher

**System Utilities:**

- `btop` - System monitor
- `zoxide` - Smart cd
- `direnv` - Environment switcher
- `nano` - Text editor with syntax highlighting
- `nmap` - Network scanner
- `cloc` - Count lines of code

**Terminal:**

- `zellij` - Terminal multiplexer
- `websocat` - WebSocket client
- `lynx` - Text web browser
- `html2text` - HTML converter

**Networking:**

- `netcat` - Network utility
- `rsync` - File synchronization
- `wget` - File downloader

**Backup & Encryption:**

- `restic` - Backup tool
- `rage` - Age encryption

**Hardware:**

- `esptool` - ESP32/ESP8266 flasher

### GUI Applications

**From Nix (home-manager):**

- `wezterm` - Terminal emulator

**From Homebrew (10 casks):**

- `cursor` - AI-powered code editor
- `zed` - Modern code editor
- `hammerspoon` - macOS automation
- `karabiner-elements` - Keyboard customization
- `temurin` - Java development kit
- `asset-catalog-tinkerer` - Xcode assets viewer
- `syntax-highlight` - Quick Look syntax highlighting
- `knockknock` - Security tool
- `osxfuse` - FUSE for macOS
- `rar` - RAR archiver

**From Homebrew (4 system integration formulae):**

- `mosquitto` - MQTT broker
- `ext4fuse` - Linux filesystem support
- `defaultbrowser` - Browser switcher
- `f3` - Flash memory tester

**From Homebrew (4 complex multimedia):**

- `ffmpeg` - Media converter
- `imagemagick` - Image processor
- `ghostscript` - PostScript interpreter
- `tesseract` - OCR engine

**Note**: ~115 Homebrew formulae are auto-dependencies for the above packages.

---

## Git Dual Identity

### How It Works

Git automatically switches between personal and work identities based on directory:

**Personal Identity** (default):

- Name: Markus Barta
- Email: markus@barta.com
- Used for: All repositories except work

**Work Identity** (BYTEPOETS):

- Name: mba
- Email: markus.barta@bytepoets.com
- Used for: Repositories in `~/Code/BYTEPOETS/`

### Configuration

Managed declaratively in `home.nix`:

```nix
programs.git = {
  userEmail = "markus@barta.com";  # Default (personal)
  userName = "Markus Barta";

  # Work identity for BYTEPOETS directory
  includes = [
    {
      condition = "gitdir:~/Code/BYTEPOETS/";
      contents = {
        user = {
          name = "mba";
          email = "markus.barta@bytepoets.com";
        };
      };
    }
  ];
};
```

### Verification

```bash
# Check personal repo
cd ~/Code/nixcfg
git config user.name    # Markus Barta
git config user.email   # markus@barta.com

# Check work repo
cd ~/Code/BYTEPOETS/some-project
git config user.name    # mba
git config user.email   # markus.barta@bytepoets.com
```

---

## Karabiner-Elements

### Overview

**Hybrid Approach**: Homebrew app + Nix configuration

- **App**: Installed via Homebrew Cask
- **Config**: Managed declaratively via home-manager

### Key Mappings

**Caps Lock → Hyper**:

- Caps Lock acts as Hyper key (Cmd+Ctrl+Opt+Shift)
- Use for global shortcuts without conflicts

**F1-F12 in Terminals**:

- Function keys work as regular F-keys in WezTerm, Terminal.app, etc.
- No need to press Fn key

**Device-Specific Settings**:

- Ignores keyboard vendor: 1133, product: 50475
- Only applies to internal keyboard

### Configuration Management

```bash
# Configuration file location
~/.config/karabiner/karabiner.json

# Managed via Nix (home.nix)
home.file.".config/karabiner/karabiner.json".source = ./config/karabiner.json;

# Edit configuration
vim ~/Code/nixcfg/hosts/imac-mba-home/config/karabiner.json

# Apply changes
home-manager switch --flake .#markus@imac-mba-home
```

### Installation

```bash
# Install Karabiner-Elements (one-time)
brew install --cask karabiner-elements

# Configuration is automatically managed by home-manager
```

**Documentation**: See `docs/manual-setup/karabiner-setup.md` for details

---

## Custom Scripts

Three essential scripts managed in git:

### flushdns.sh

Flush macOS DNS cache

```bash
# Usage
flushdns

# Or directly
~/Scripts/flushdns.sh
```

### pingt.sh

Timestamped ping (pure bash implementation)

```bash
# Usage (via Fish abbreviation)
pingt 192.168.1.1

# Or directly
~/Scripts/pingt.sh 192.168.1.1
```

### stopAmphetamineAndSleep.sh

Stop Amphetamine and put Mac to sleep

```bash
# Usage
~/Scripts/stopAmphetamineAndSleep.sh
```

### Script Management

**Location**: `~/Scripts/` (symlinked by home-manager)

**Source**: `hosts/imac-mba-home/scripts/host-user/`

**Deployment**:

```nix
# In home.nix
home.file."Scripts" = {
  source = ./scripts/host-user;
  recursive = true;
};
```

---

## System Management

### Updating Configuration

```bash
# Pull latest changes
cd ~/Code/nixcfg
git pull

# Apply configuration
home-manager switch --flake .#markus@imac-mba-home

# Verify
which fish node python3
# All should point to ~/.nix-profile/bin/
```

### Updating Packages

```bash
# Update flake inputs (Nix packages)
cd ~/Code/nixcfg
nix flake update

# Rebuild with new versions
home-manager switch --flake .#markus@imac-mba-home

# Update Homebrew packages
brew upgrade
```

### Useful Commands

```bash
# Check Nix PATH priority
echo $PATH
# Should start with: /Users/markus/.nix-profile/bin

# Verify tool sources
which fish    # ~/.nix-profile/bin/fish
which node    # ~/.nix-profile/bin/node
which python3 # ~/.nix-profile/bin/python3

# Check home-manager version
home-manager --version

# Clean up old generations
home-manager expire-generations "-7 days"
nix-collect-garbage -d

# View system info
system_profiler SPSoftwareDataType SPHardwareDataType
```

---

## Troubleshooting

### PATH Issues

**Symptom**: Commands resolve to Homebrew instead of Nix

**Solution**: Check Fish login shell initialization

```bash
# Verify Nix paths come first
echo $PATH

# Should start with:
# /Users/markus/.nix-profile/bin:/nix/var/nix/profiles/default/bin

# If not, reload shell
exec fish
```

### Nerd Font Icons Missing

**Symptom**: Starship prompt shows boxes instead of icons

**Solution**: Check font configuration

```bash
# Verify Hack Nerd Font is installed
ls ~/Library/Fonts/ | grep Hack

# If missing, refresh fonts
killall fontd

# Reapply home-manager
home-manager switch --flake .#markus@imac-mba-home
```

### Git Identity Not Switching

**Symptom**: Wrong git identity in work repository

**Solution**: Verify git configuration

```bash
# Check current identity
cd ~/Code/BYTEPOETS/some-project
git config user.email

# Should show: markus.barta@bytepoets.com

# If wrong, check includeIf path
git config --list --show-origin | grep includeIf
```

### Karabiner Not Working

**Symptom**: Caps Lock doesn't act as Hyper key

**Solution**:

1. Check Karabiner-Elements is running (menu bar icon)
2. Grant system permissions (System Settings → Privacy & Security)
3. Restart Karabiner-Elements
4. Verify configuration:

```bash
cat ~/.config/karabiner/karabiner.json | jq '.profiles[0].complex_modifications.rules[0].description'
# Should show: "Caps Lock to Hyper (Ctrl+Option+Cmd)"
```

### Home-Manager Build Fails

**Symptom**: `home-manager switch` fails with error

**Common Solutions**:

```bash
# Update flake inputs
nix flake update

# Clear Nix cache
rm -rf ~/.cache/nix

# Verify syntax
nix flake check

# Try dry-run first
home-manager switch --flake .#markus@imac-mba-home --dry-run
```

### macOS Network Tools (ping) Issues

**Symptom**: Nix ping shows negative/incorrect times

**Solution**: Use macOS native ping (already aliased)

```bash
# Fish alias forces native ping
which ping
# Output: ping: aliased to /sbin/ping

# Test
ping -c 3 8.8.8.8
# Should show normal ping times (not negative numbers)
```

---

## Migration History

### Overview

**Date**: November 14-15, 2025  
**Duration**: ~24 hours  
**Status**: ✅ Complete

**Key Milestones:**

- ✅ Pre-migration backup (56 files, checksums verified)
- ✅ Infrastructure setup (home.nix, flake integration)
- ✅ Core environment testing (Fish, Starship, WezTerm, Git)
- ✅ Post-migration PATH fix (Nix priority over Homebrew)
- ✅ Reboot testing (persistence verification)
- ✅ Homebrew cleanup (167 → 127 formulae)
- ✅ Special configurations (Nerd Fonts, GUI apps, Karabiner)

### Migration Achievements

**Packages Migrated**: 45+ packages from Homebrew to Nix

- Shell: Fish, Starship
- Terminal: WezTerm
- Dev Tools: Node.js, Python, Git, gh, jq, just, lazygit
- CLI Tools: bat, btop, ripgrep, fd, fzf, zoxide, tree, mc
- Network: netcat, websocat, lynx, rsync, wget
- Backup: restic, rage

**Space Savings**: ~460MB net (after accounting for Nix additions)

**Configuration**: 100% declarative via home-manager

### Complete Documentation

**See**: `docs/archive/MIGRATION-2025-11 [DONE].md` for comprehensive migration history, including:

- Detailed timeline and milestones
- Technical challenges and solutions
- Special configurations (Karabiner, GUI apps, network tools)
- Homebrew cleanup analysis
- Lessons learned
- Rollback procedures

---

## Related Documentation

### In This Host

- **[Migration History](./archive/MIGRATION-2025-11%20[DONE].md)** - Complete migration documentation
- **[Manual Setup](./manual-setup/)** - One-time setup guides (Karabiner, fonts)

### In Repository

- **[Main README](../../../README.md)** - Repository overview
- **[How It Works](../../../docs/how-it-works.md)** - Architecture
- **[Hokage Options](../../../docs/hokage-options.md)** - Server configuration reference

### Configuration Files

- **[home.nix](../home.nix)** - Main configuration
- **[starship.toml](../config/starship.toml)** - Prompt configuration
- **[karabiner.json](../config/karabiner.json)** - Keyboard mappings

---

## Changelog

### 2025-11-23: Documentation Consolidation

- ✅ Created comprehensive migration archive document
- ✅ Updated README to match server pattern (hsb8/hsb0)
- ✅ Consolidated 7 reference docs into single archive
- ✅ Improved navigation and structure

### 2025-11-15: Migration Complete

- ✅ All 45+ packages migrated to Nix
- ✅ Homebrew reduced to 127 formulae
- ✅ System 100% functional
- ✅ Ready for production use

### 2025-11-14: Initial Migration

- ✅ Infrastructure setup
- ✅ Core environment testing
- ✅ PATH configuration fix
- ✅ Special configurations (fonts, GUI apps, Karabiner)

---

**Current Status**: ✅ Production-ready workstation, fully declarative core, daily driver

**Next Step**: Use as template for `imac-27-work` migration

---

**Last Updated**: November 23, 2025  
**Maintainer**: Markus Barta  
**Repository**: https://github.com/markus-barta/nixcfg
