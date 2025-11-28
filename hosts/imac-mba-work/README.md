# imac-mba-work - Work iMac (BYTEPOETS)

Work macOS development machine with Nix package management.

## Quick Links

- 🧪 **[Test Suite](tests/README.md)** - Validation tests for this configuration
- 📖 **[Manual Setup](docs/manual-setup.md)** - One-time configuration steps
- 📚 **[imac0 README](../imac0/README.md)** - Home iMac (similar configuration)

---

## Quick Reference

| Item               | Value                                            |
| ------------------ | ------------------------------------------------ |
| **Hostname**       | `imac-mba-work`                                  |
| **Model**          | iMac 27" (2019) - iMac19,1                       |
| **CPU**            | Intel Core i9-9900K @ 3.6GHz (8C/16T)            |
| **RAM**            | 16 GB DDR4                                       |
| **Storage**        | 1 TB Apple SSD SM1024L (APFS)                    |
| **Storage Used**   | ~10 GB system, ~10 GB Nix store (211 GB free)    |
| **OS**             | macOS 15.7.2 Sequoia (24G325)                    |
| **Architecture**   | x86_64 (Intel, Hyper-Threading enabled)          |
| **User**           | `markus`                                         |
| **Shell**          | Fish (via Nix)                                   |
| **Terminal**       | WezTerm (via Nix)                                |
| **Config Manager** | home-manager (standalone)                        |
| **Nix Packages**   | ~37 packages (declarative)                       |
| **Homebrew**       | ~110 formulae + 4 casks (5 explicit)             |
| **Git Default**    | Work identity (mba / markus.barta@bytepoets.com) |
| **Apply Config**   | `just switch` or `home-manager switch --flake .` |

---

## Current State (2025-11-28)

### 🚀 **CONFIGURED & OPERATIONAL**

**Package Management**:

- ✅ Homebrew vs Nix analysis complete (see [Package Manager Analysis](#package-manager-analysis-2025-11-28))
- ✅ Homebrew cleanup complete (5 explicit packages remaining)
- ✅ CLI tools migrated to Nix (cloc, watch)
- ✅ Unused packages removed (topgrade, go-jira, lizard, python@3.11, python@3.9)

**Core Configuration**:

- ✅ Fish shell (shared config from `modules/shared/fish-config.nix`)
- ✅ Starship prompt (shared config from `modules/shared/starship.toml`)
- ✅ WezTerm terminal (shared config)
- ✅ Git with work identity (BYTEPOETS default)
- ✅ CLI development tools
- ✅ Karabiner-Elements keyboard remapping
- ✅ devenv development environment

**Git Identity**:

- **Default (Work)**: mba / markus.barta@bytepoets.com
- **Personal** (~/Code/personal/, ~/Code/nixcfg/): Markus Barta / markus@barta.com

---

## Features

imac-mba-work provides a complete development environment:

| ID  | Technical             | User-Friendly                                    | Test |
| --- | --------------------- | ------------------------------------------------ | ---- |
| F00 | Nix Base System       | Reproducible package management with Flakes      | T00  |
| F01 | Fish Shell            | Modern shell with custom functions & aliases     | T01  |
| F02 | Git Dual Identity     | Auto-switch between work/personal Git identities | T02  |
| F03 | Starship Prompt       | Beautiful, informative prompt with Git status    | T03  |
| F04 | WezTerm Terminal      | GPU-accelerated terminal with custom config      | T04  |
| F05 | CLI Development Tools | bat, ripgrep, fd, fzf, btop, zoxide, jq, just    | T05  |
| F06 | direnv + devenv       | Automatic project environment loading            | T06  |
| F07 | Karabiner-Elements    | Caps Lock → Hyper, F-keys in terminals           | T07  |
| F08 | Nerd Fonts            | Hack Nerd Font for terminal icons                | T08  |

**Test Documentation**: All features have test procedures in `hosts/imac-mba-work/tests/` with both manual instructions and automated scripts.

---

## Fresh Machine Setup

### 1. Install Nix

```bash
# Install Nix (Determinate Systems installer - recommended)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# Restart terminal, verify installation
nix --version
```

**Note**: The Determinate Systems installer automatically configures `trusted-users`, which enables faster builds with binary caches.

### 2. Clone & Apply Configuration

```bash
# Clone repository
git clone https://github.com/pbek/nixcfg ~/Code/nixcfg
cd ~/Code/nixcfg

# Install home-manager and apply configuration
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

### 4. Configure Nix trusted-users (if needed)

If you see "Failed to set up binary caches" warnings:

```bash
# Edit Nix configuration
sudo nano /etc/nix/nix.conf

# Add this line:
trusted-users = root markus

# Restart nix-daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

### 5. Manual Installations

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
├── docs/                        # Documentation
│   └── manual-setup.md          # One-time setup guides
│
├── scripts/
│   ├── setup/                   # Setup scripts
│   └── host-user/               # Daily user utilities
│
├── tests/                       # Test suite
│   ├── README.md                # Test overview & status
│   ├── T00-nix-base.md/sh       # Nix base system tests
│   ├── T01-fish-shell.md/sh     # Fish shell tests
│   └── ...                      # More tests
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

## Hardware Specifications

### System Details

- **Model**: iMac 27" Retina 5K (2019)
- **Model Identifier**: iMac19,1
- **CPU**: Intel Core i9-9900K @ 3.6 GHz
  - 8 cores, 16 threads (Hyper-Threading enabled)
  - Coffee Lake architecture (9th generation)
  - L2 Cache: 256 KB per core
  - L3 Cache: 16 MB shared
- **RAM**: 16 GB DDR4
- **GPU**: AMD Radeon Pro 580X (8 GB VRAM)
- **Display**: 27" Retina 5K (5120 x 2880)

### Storage

- **Drive**: Apple SSD SM1024L
  - **Type**: NVMe SSD (PCI-Express)
  - **Capacity**: 1 TB (932 GB formatted)
  - **Filesystem**: APFS (Apple File System)
  - **S.M.A.R.T. Status**: Verified
- **Usage** (as of 2025-11-28):
  - System: ~10 GB
  - Nix Store: ~10 GB
  - Free: ~211 GB (77% available)

### Disk Layout

```text
Filesystem      Size   Used  Avail  Capacity  Mounted on
/dev/disk1s5s1  932G   10G   211G   5%        /           (macOS System)
/dev/disk1s7    932G   10G   211G   5%        /nix        (Nix Store)
/dev/disk1s1    932G   ---   ---    ---       /Data       (User Data)
```

### Software

- **OS**: macOS 15.7.2 Sequoia (Build 24G325)
- **Architecture**: x86_64 GNU/Darwin
- **Firmware**: 2075.100.3.0.3
- **SMC Version**: 2.46f12

---

## Package Managers

### Nix (Primary)

- **Manager**: home-manager (standalone, user-level)
- **Packages**: ~35 declarative packages
- **Store Location**: `/nix` (dedicated APFS volume)
- **Profile**: `~/.nix-profile/bin/`

### Homebrew (Secondary)

- **Formulae**: 118 total (14 explicitly installed)
- **Casks**: 4 GUI applications
- **Purpose**: GUI apps, complex multimedia, macOS-specific tools

### Key Binaries (from Nix)

```bash
which fish git node python3 starship wezterm bat rg fd
# All should show ~/.nix-profile/bin/...
```

### Verify Nix vs Homebrew

```bash
# Check where a binary comes from
which python3   # Should be ~/.nix-profile/bin/python3
which ffmpeg    # Should be /opt/homebrew/bin/ffmpeg (Homebrew)
```

---

## Making Changes

### Update Configuration

```bash
cd ~/Code/nixcfg

# Edit configuration
vim hosts/imac-mba-work/home.nix

# Apply changes (platform-aware: detects macOS and runs home-manager)
just switch

# Or directly:
home-manager switch --flake ".#markus@imac-mba-work"

# Commit to git
git add hosts/imac-mba-work/
git commit -m "Update imac-mba-work configuration"
git push
```

### Update Shared Config (affects all Macs)

```bash
# Edit shared config
vim modules/shared/fish-config.nix

# Apply to this machine
just switch

# Apply to home machine (when there)
just switch  # on imac0
```

---

## Differences from imac0 (Home)

| Feature          | imac0 (Home)               | imac-mba-work (Work)        |
| ---------------- | -------------------------- | --------------------------- |
| **Git Default**  | Personal identity          | Work identity (BYTEPOETS)   |
| **Git Includes** | Work for ~/Code/BYTEPOETS/ | Personal for ~/Code/nixcfg/ |
| **esptool**      | ✅ Installed               | ❌ Not needed               |
| **nmap**         | ✅ Installed               | ❌ Not needed               |

**Shared between both**:

- Fish shell config
- Starship prompt
- WezTerm terminal
- CLI tools (bat, rg, fd, fzf, btop, zoxide, jq, just)
- Karabiner keyboard remapping
- direnv + devenv

---

## Package Manager Analysis (2025-11-28)

### Current State

**Homebrew**: ~110 formulae + 4 casks  
**Explicitly installed** (leaves): 5 formulae + 4 casks  
**Most Homebrew packages**: Dependencies of ffmpeg (~60) and openvino (~15)

**Nix (via home-manager)**: ~35 packages  
All CLI development tools, shell, terminal, and interpreters managed declaratively.

### Homebrew Explicit Packages (Leaves)

| Package          | Description                     | Recommendation             |
| ---------------- | ------------------------------- | -------------------------- |
| `blueutil`       | Bluetooth CLI                   | ✅ Keep - macOS specific   |
| `cloc`           | Lines of code counter           | ✅ Migrated to Nix         |
| `defaultbrowser` | Set default browser             | ✅ Keep - macOS specific   |
| `docker`         | Container runtime               | ✅ Removed (unused)        |
| `docker-compose` | Container orchestration         | ✅ Removed (unused)        |
| `ffmpeg`         | Video processing                | ✅ Keep - Complex deps     |
| `go-jira`        | Jira CLI                        | ✅ Removed (unused)        |
| `lizard`         | Compression (NOT code analyzer) | ✅ Removed (unused)        |
| `openjdk`        | Java runtime                    | ✅ Keep - Dev toolchain    |
| `openvino`       | Intel AI toolkit                | ✅ Keep - Complex deps     |
| `python@3.11`    | Python 3.11                     | ✅ Removed - No dependents |
| `python@3.9`     | Python 3.9                      | ✅ Removed - No dependents |
| `topgrade`       | System updater                  | ✅ Removed (unused)        |
| `watch`          | Run command periodically        | ✅ Migrated to Nix         |

**Casks (GUI Apps)**:
| Cask | Description | Recommendation |
| ------------- | ----------------- | ------------------------ |
| `ghostty` | Terminal emulator | ✅ Keep - GUI app |
| `hammerspoon` | macOS automation | ✅ Keep - GUI/System |
| `macdown` | Markdown editor | ✅ Keep - GUI app |
| `zed` | Code editor | ✅ Keep - GUI app |

### Duplicate Analysis

| Tool   | Nix Version | Homebrew Version | Active | Recommendation           |
| ------ | ----------- | ---------------- | ------ | ------------------------ |
| Python | 3.13 ✅     | 3.11, 3.9        | Nix    | Remove Homebrew versions |

**No other duplicates found** - Good separation between Brew and Nix!

### Migration Recommendations

#### 1. Remove Unused Python Versions ⚠️

The Homebrew Python versions have **no dependents** and Nix python3 (3.13) is active:

```bash
# Verify no dependencies
brew uses --installed python@3.11 python@3.9
# (should return empty)

# Remove old versions
brew uninstall python@3.11 python@3.9
```

#### 2. CLI Tools Migrated ✅

Completed on 2025-11-28:

- **cloc** → Added to `macos-common.nix` (nixpkgs.cloc)
- **watch** → Added to `macos-common.nix` (nixpkgs.procps)
- **topgrade** → Removed from Homebrew (unused)

```bash
# Verify Nix versions are active:
which cloc watch  # Should show ~/.nix-profile/bin/
```

#### 3. Review Usage ❓

Check if these are actually used before deciding:

- **go-jira**: Removed from imac0 as unused. Still using Jira CLI here?
- **topgrade**: Removed from imac0 as unused. Still using system updater?
- **lizard**: Compression library - check if needed for projects

```bash
# Check last usage (if logged)
which jira topgrade
```

### What Should Stay in Homebrew (Learnings from imac0)

Based on the [imac0 migration](../imac0/archive/MIGRATION-2025-11%20[DONE].md):

**GUI Applications** (10 casks) ✅

- Better macOS integration (Spotlight, Dock, permissions)
- Cursor, Zed, Hammerspoon, Ghostty, etc.

**Complex Multimedia** ✅

- `ffmpeg` - 60+ codec dependencies, Nix causes dependency hell
- Avoid rebuilding video codecs on every update

**System Integration** ✅

- `docker`, `docker-compose` - Native macOS socket integration
- `blueutil`, `defaultbrowser` - macOS-specific utilities

**Heavy Dependencies** ✅

- `openvino` - Intel AI toolkit with 15+ specialized deps
- `openjdk` - Java with macOS integration

**Pattern**: Keep in Homebrew if:

1. GUI app requiring macOS permissions/integration
2. Complex native dependencies (multimedia, AI, system)
3. macOS-specific utilities with no Linux equivalent
4. Rarely updated, heavy build tools

### What Belongs in Nix (Declarative)

**Shell & Terminal** ✅ (already migrated)

- fish, starship, wezterm, zellij

**CLI Development Tools** ✅ (already migrated)

- git, gh, jq, just, lazygit, bat, ripgrep, fd, fzf, eza

**Interpreters** ✅ (already migrated)

- nodejs, python3

**Additional CLI to migrate**:

- cloc, watch (see above)

### Package Count Summary

| Category               | Count | Manager  |
| ---------------------- | ----- | -------- |
| **Shell & Terminal**   | 5     | Nix ✅   |
| **CLI Dev Tools**      | 15+   | Nix ✅   |
| **Interpreters**       | 2     | Nix ✅   |
| **GUI Apps**           | 4     | Homebrew |
| **Multimedia**         | 1+60  | Homebrew |
| **System Integration** | 5     | Homebrew |
| **To Review**          | 3-5   | TBD      |

### Cleanup Complete ✅

All cleanup tasks completed on 2025-11-28:

1. [x] ~~Remove `python@3.11` and `python@3.9`~~ ✅ Removed
2. [x] ~~Add `cloc` to Nix~~ ✅ Done
3. [x] ~~Add `watch` to Nix~~ ✅ Done (via procps)
4. [x] ~~Remove `topgrade`~~ ✅ Removed
5. [x] ~~Remove `go-jira`, `lizard`~~ ✅ Removed
6. [x] ~~Run `brew autoremove`~~ ✅ Auto-removed: gdbm, mpdecimal, readline, sqlite, ncurses

---

## Troubleshooting & FAQ

### devenv / direnv Issues

#### Q: "devenv: command not found" when entering nixcfg directory

**Cause**: devenv is not installed on this machine.

**Solution**:

```bash
# Install devenv via Nix
nix profile install "nixpkgs#devenv"
```

#### Q: "use_devenv: command not found" in direnv

**Cause**: devenv is not in PATH when direnv runs.

**Solution**: Install devenv (see above), then reload direnv:

```bash
cd ~/Code/nixcfg
direnv allow
direnv reload
```

#### Q: ".shared/common.just" import error in justfile

**Cause**: The `.shared/common.just` file is created by devenv (from `github:pbek/nix-shared`). If devenv hasn't run yet, the file doesn't exist.

**Solution**: Let devenv create it:

```bash
cd ~/Code/nixcfg
devenv shell -- echo "Shell loaded"
# This creates .shared/common.just automatically
```

**Note**: Don't create this file manually - devenv manages it as a symlink to the nix store.

#### Q: "Conflicting file .shared/common.just"

**Cause**: You manually created `.shared/common.just`, but devenv wants to manage it.

**Solution**:

```bash
rm -rf ~/Code/nixcfg/.shared
cd ~/Code/nixcfg
devenv shell -- echo "Recreated"
```

---

### Nix Cache / Build Issues

#### Q: "Failed to set up binary caches" and builds are slow

**Cause**: Your user is not in `trusted-users`, so Nix can't use binary caches and builds everything from source.

**Solution**:

```bash
# Edit /etc/nix/nix.conf
sudo nano /etc/nix/nix.conf

# Add this line:
trusted-users = root markus

# Restart nix-daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon

# Verify by reloading direnv in nixcfg
cd ~/Code/nixcfg && direnv reload
# Should no longer show "Failed to set up binary caches"
```

**Why this happens**: On NixOS, `trusted-users` is configured declaratively in `modules/common.nix`. On macOS with standalone home-manager, `/etc/nix/nix.conf` is a system file that home-manager can't modify - you need to configure it manually once.

**Tip**: The [Determinate Systems Nix installer](https://github.com/DeterminateSystems/nix-installer) automatically sets this up. If you used the official installer, you need to add it manually.

#### Q: devenv shell takes 5+ minutes to build

**Cause**: First-time build without binary caches (see above).

**Solution**: Configure `trusted-users` (see above). After that, the shell loads in seconds.

---

### Shell / Terminal Issues

#### Q: Commands not found after `just switch`

**Solution**: Restart your shell or terminal:

```bash
exec fish
# or just open a new terminal tab
```

#### Q: PATH doesn't prioritize Nix binaries

**Check**:

```bash
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

**Fix**: The Fish login shell init should handle this. If not:

```bash
# Manually prioritize (temporary)
fish_add_path --prepend --move ~/.nix-profile/bin
```

---

### Git Issues

#### Q: Wrong Git identity used

**Check current identity**:

```bash
git config user.email
```

**Verify include condition**:

```bash
cd ~/Code/nixcfg  # Should use personal identity
git config user.email  # → markus@barta.com

cd ~/Code/BYTEPOETS/some-project  # Should use work identity
git config user.email  # → markus.barta@bytepoets.com
```

**Fix**: Check `home.nix` → `programs.git.includes` configuration.

---

### Karabiner Issues

#### Q: Caps Lock → Hyper not working

1. Check Karabiner-Elements is running (menu bar icon)
2. System Preferences → Security & Privacy → Privacy → Input Monitoring
3. Ensure "karabiner_grabber" and "Karabiner-Elements" are enabled
4. Restart Karabiner:

```bash
killall karabiner_console_user_server
```

---

## Useful Commands

```bash
# Apply configuration
just switch                 # Platform-aware switch
just home-switch            # Explicit home-manager switch

# Update everything
just update                 # Update flake inputs
just upgrade                # Update + switch

# devenv management
devenv shell                # Enter development shell
devenv update               # Update devenv.lock

# System info
nix --version               # Nix version
home-manager --version      # home-manager version
which fish git node python3 # Verify Nix binaries

# Troubleshooting
direnv reload               # Reload environment
exec fish                   # Restart shell
```

---

## Related Documentation

- [imac0 README](../imac0/README.md) - Home iMac configuration (similar setup)
- [Main Repository README](../../README.md) - Repository overview
- [Hosts README](../README.md) - All hosts documentation
- [Shared Modules](../../modules/shared/README.md) - Shared configuration documentation

---

## Changelog

### 2025-11-28: Package Manager Analysis & CLI Migration

- Added comprehensive Homebrew vs Nix analysis section
- Identified duplicate Python versions (Homebrew 3.11/3.9 vs Nix 3.13)
- Migrated CLI tools to Nix:
  - `cloc` → added to macos-common.nix
  - `watch` → added via procps to macos-common.nix
  - `topgrade` → removed (unused)
- Homebrew reduced: 118 → 114 formulae, 14 → 11 explicit packages

### 2025-11-28: Documentation & Test Suite Added

- Added Quick Reference table
- Added Features table with test IDs
- Created comprehensive test suite (9 tests)
- Added Troubleshooting/FAQ section with devenv learnings
- Documented trusted-users and binary cache configuration

### 2025-11-27: Initial Configuration

- Initial setup with home-manager
- Fish shell, Starship, WezTerm configured
- Git dual identity (work default, personal for nixcfg)
- Karabiner-Elements keyboard remapping
- CLI development tools installed

---

**Last Updated**: November 28, 2025
**Maintainer**: Markus Barta
