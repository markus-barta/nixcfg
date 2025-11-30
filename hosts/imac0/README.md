# imac0 - macOS Development Workstation

Personal macOS development machine with Nix package management and home-manager.

## Quick Reference

| Item                 | Value                                        |
| -------------------- | -------------------------------------------- |
| **Hostname**         | `imac0` (formerly `imac-mba-home`)           |
| **Model**            | iMac 27" 5K Retina (2019) - iMac19,1         |
| **CPU**              | Intel Core i9-9900K @ 3.60GHz (8C/16T)       |
| **RAM**              | 16 GB DDR4 @ 2667 MHz (4×4GB, upgradeable)   |
| **GPU**              | AMD Radeon Pro Vega 48 (8 GB VRAM)           |
| **Display**          | Built-in Retina 5K (5120×2880, 30-bit color) |
| **Storage**          | 1TB Apple SSD SM1024L (NVMe, APFS)           |
| **External Storage** | Samsung Portable SSD T5 (500GB, USB)         |
| **Network**          | Gigabit Ethernet (`en0`)                     |
| **Static IP**        | `192.168.1.150/24` (DHCP reservation)        |
| **MAC Address**      | `38:f9:d3:0e:e1:c6`                          |
| **Gateway**          | `192.168.1.5` (Fritz!Box)                    |
| **DNS**              | `192.168.1.99` (hsb0 - AdGuard Home)         |
| **OS**               | macOS 15.7.2 Sequoia (Build 24G325)          |
| **Serial Number**    | `DGKYPHDYJV40`                               |
| **User**             | `markus` (Markus Barta)                      |
| **Configuration**    | home-manager + Nix flakes                    |

## Quick Links

- 📖 **[Progress & History](docs/progress.md)** - Migration status & complete history
- 🛠️ **[Manual Setup Guides](docs/manual-setup/)** - One-time configuration steps
- 📚 **[Technical Reference](docs/reference/)** - Deep dives into specific features
- 📁 **[Documentation Index](docs/README.md)** - Full docs structure

---

## Features

| ID  | Technical                   | User-Friendly                            | Test |
| --- | --------------------------- | ---------------------------------------- | ---- |
| F00 | home-manager + Nix          | Declarative package & config management  | -    |
| F01 | Fish Shell + Starship       | Modern shell with beautiful prompt       | -    |
| F02 | WezTerm                     | GPU-accelerated terminal emulator        | -    |
| F03 | Git Dual Identity           | Auto-switch personal/work git identity   | -    |
| F04 | Karabiner-Elements          | Caps Lock → Hyper key, custom mappings   | -    |
| F05 | Zellij Terminal Multiplexer | Modern tmux alternative with tabs/panes  | -    |
| F06 | Tokyo Night Theme           | Consistent theming across tools          | -    |
| F07 | direnv + devenv             | Project-specific dev environments        | -    |
| F08 | Nix Build Host              | Fast builds with 16 threads and 16GB RAM | -    |

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
- ✅ Homebrew cleanup complete (127 formulae, 10 casks remaining)
- ✅ ~700MB freed from Homebrew (~460MB net)

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
home-manager switch --flake ".#markus@imac-mba-home"
```

### 2. Run One-Time System Setup

```bash
# Set Nix fish as default login shell (requires sudo)
./hosts/imac-mba-home/scripts/setup/setup-macos.sh

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

```text
hosts/imac0/
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
│       ├── macos-network-tools.md
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

## Hardware Specifications

### System Details

- **Model**: iMac 27" 5K Retina (Late 2019)
- **Model Identifier**: iMac19,1
- **Serial Number**: `DGKYPHDYJV40`
- **Hardware UUID**: `5F080685-4766-54A5-8DDB-E8C23ECA2B00`

### CPU

- **Processor**: Intel Core i9-9900K @ 3.60 GHz
  - **Cores/Threads**: 8 cores, 16 threads (Hyper-Threading)
  - **Architecture**: Coffee Lake (9th generation)
  - **L2 Cache**: 256 KB per core (2 MB total)
  - **L3 Cache**: 16 MB (shared)
  - **Features**: AVX2, AES-NI, Intel VT-x
- **Performance**: **Fastest CPU** in the infrastructure
  - 2× threads vs gpc0 (16 vs 8)
  - Similar single-thread to i7-7700K

### GPU

- **Graphics**: AMD Radeon Pro Vega 48
  - **VRAM**: 8 GB HBM2
  - **Bus**: PCIe x16
  - **Metal Support**: Metal 3
  - **Vendor ID**: `1002:6869`
  - **ROM**: 113-D0650E-072

### Display

- **Built-in**: Retina 5K LCD
  - **Resolution**: 5120 × 2880 (14.7 megapixels)
  - **Color Depth**: 30-bit (ARGB2101010)
  - **P3 Wide Color**: Yes
  - **True Tone**: Yes
  - **Brightness**: Auto-adjust

### Memory

- **Total**: 16 GB DDR4 @ 2667 MHz
- **Slots**: 4 (all populated with 4GB modules)
- **Upgradeable**: Yes (up to 128 GB)

| Slot | Size | Type | Speed    | Manufacturer | Part Number      |
| ---- | ---- | ---- | -------- | ------------ | ---------------- |
| 0    | 4 GB | DDR4 | 2667 MHz | SK Hynix     | HMA851S6CJR6N-VK |
| 1    | 4 GB | DDR4 | 2667 MHz | Kingston     | 9905711-008.A00G |
| 2    | 4 GB | DDR4 | 2667 MHz | SK Hynix     | HMA851S6CJR6N-VK |
| 3    | 4 GB | DDR4 | 2667 MHz | Kingston     | 9905711-008.A00G |

### Storage

| Device       | Model               | Size   | Interface | Mount Points           |
| ------------ | ------------------- | ------ | --------- | ---------------------- |
| Internal SSD | Apple SSD SM1024L   | 1 TB   | NVMe/PCIe | `/`, `/nix`, `/Data`   |
| External SSD | Samsung Portable T5 | 500 GB | USB 3.1   | `/Volumes/500GB ExFAT` |

**Disk Layout (APFS Container)**:

```text
/dev/disk1 (Apple SSD SM1024L - 1TB NVMe)
├─ disk1s1     /System/Volumes/Data    622 GB used (90%)
├─ disk1s5s1   /                       10 GB (system, sealed)
├─ disk1s7     /nix                    27 GB (Nix store)
└─ (other system volumes)

Free Space: ~74 GB available
S.M.A.R.T. Status: Verified ✅
```

### Network

- **Interface**: Gigabit Ethernet (`en0`)
- **MAC Address**: `38:f9:d3:0e:e1:c6`
- **IP Address**: `192.168.1.150/24` (DHCP static lease)
- **Gateway**: `192.168.1.5` (Fritz!Box)
- **DNS**: `192.168.1.99` (hsb0 - AdGuard Home)

### Software

- **OS**: macOS 15.7.2 Sequoia (Build 24G325)
- **Architecture**: x86_64 (Intel)
- **Firmware**: 2075.100.3.0.3
- **SMC Version**: 2.46f12

---

## Nix Build Capabilities

imac0 is the **most powerful Nix build machine** in the infrastructure:

### Build Performance

| Metric            | Value                       | Comparison                  |
| ----------------- | --------------------------- | --------------------------- |
| **CPU Threads**   | 16 (8C × 2T)                | 2× more than gpc0           |
| **CPU Speed**     | 3.60 GHz (boost to 5.0 GHz) | Excellent single-thread     |
| **RAM**           | 16 GB DDR4                  | Same as gpc0/hsb1           |
| **Storage Speed** | NVMe SSD (Apple SM1024L)    | Very fast random I/O        |
| **Architecture**  | x86_64 (native)             | No cross-compilation needed |

### Use Cases

1. **Local home-manager Rebuilds**

   ```bash
   cd ~/Code/nixcfg
   home-manager switch --flake ".#markus@imac0"
   ```

2. **Building for NixOS Hosts** (cross-build to Linux)

   ```bash
   # Build configuration (may need Linux builder for some packages)
   nix build .#nixosConfigurations.hsb0.config.system.build.toplevel
   ```

3. **Nix Package Development**

   ```bash
   # Build local packages
   nix build .#qownnotes
   nix build .#nixbit

   # Enter development shell
   nix develop
   ```

4. **Remote Builds via SSH**
   ```bash
   # Use imac0 as a remote builder from other machines
   # (requires Nix daemon configuration)
   ```

### Build Time Comparison

| Host      | CPU                | Threads | Architecture | Typical Build   |
| --------- | ------------------ | ------- | ------------ | --------------- |
| **imac0** | i9-9900K @ 3.60GHz | 16      | Darwin/x86   | **~2-3 min** ⚡ |
| gpc0      | i7-7700K @ 4.20GHz | 8       | Linux/x86    | ~2-5 min        |
| hsb1      | i7-4578U @ 3.00GHz | 4       | Linux/x86    | ~5-10 min       |
| hsb0      | i5-2415M @ 2.30GHz | 4       | Linux/x86    | ~8-15 min       |

**Note**: imac0 runs macOS, so building NixOS system configurations requires either:

- A Linux remote builder (e.g., gpc0, hsb1)
- Docker/Podman with Linux VM
- home-manager only (native Darwin)

---

## System Information

### Package Managers

- **Nix**: Primary (~45 declarative packages)
- **Homebrew**: Secondary (127 formulae + 10 casks - GUI apps, multimedia, system integration)

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

- **Personal** (default): Markus Barta / `markus@barta.com`
- **Work** (`~/Code/BYTEPOETS/`): mba / `markus.barta@bytepoets.com`

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
vim hosts/imac-mba-home/home.nix

# Apply changes
home-manager switch --flake ".#markus@imac-mba-home"

# Commit to git
git add hosts/imac-mba-home/home.nix
git commit -m "Update configuration"
git push
```

### Add New Script

```bash
# Create script in host-user directory
vim hosts/imac-mba-home/scripts/host-user/new-script.sh
chmod +x hosts/imac-mba-home/scripts/host-user/new-script.sh

# Commit to git
git add hosts/imac-mba-home/scripts/host-user/new-script.sh
git commit -m "Add new-script"

# Apply changes (script automatically symlinked to ~/Scripts/)
home-manager switch --flake ".#markus@imac-mba-home"
```

### Update Karabiner Mappings

```bash
# Edit configuration
vim hosts/imac-mba-home/config/karabiner.json

# Commit changes
git add hosts/imac-mba-home/config/karabiner.json
git commit -m "Update keyboard mappings"

# Apply changes
home-manager switch --flake ".#markus@imac-mba-home"

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

### Ping Shows Crazy Negative Times

If you see astronomically large negative ping times like `-1084818903855532605440.000 ms`, you're using the wrong ping binary.

**Solution**: We alias `ping` to use macOS native `/sbin/ping` to avoid the Linux ping bug.

Verify:

```bash
which ping  # Should show: ping: aliased to /sbin/ping
```

See [docs/reference/macos-network-tools.md](docs/reference/macos-network-tools.md) for details.

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

## Relationship with Other Hosts

### Network Dependencies

- **DNS**: Uses hsb0 (192.168.1.99) via AdGuard Home
- **DHCP**: Static lease assigned by hsb0
- **Ad-blocking**: Network-wide filtering via AdGuard Home

### SSH Connections

imac0 connects to other hosts via zellij abbreviations:

```bash
hsb0    # → ssh mba@192.168.1.99 with zellij
hsb1    # → ssh mba@192.168.1.101 with zellij
hsb8    # → ssh mba@192.168.1.100 with zellij
csb0    # → ssh mba@cs0.barta.cm:2222 with zellij
csb1    # → ssh mba@cs1.barta.cm:2222 with zellij
```

### Performance Comparison

| Host      | CPU             | Threads | RAM   | GPU               | Role            |
| --------- | --------------- | ------- | ----- | ----------------- | --------------- |
| **imac0** | i9-9900K 3.6GHz | 16      | 16 GB | Vega 48 (8GB)     | Dev Workstation |
| gpc0      | i7-7700K 4.2GHz | 8       | 16 GB | RX 9070 XT (16GB) | Gaming PC       |
| hsb1      | i7-4578U 3.0GHz | 4       | 16 GB | Intel Iris        | Home Automation |
| hsb0      | i5-2415M 2.3GHz | 4       | 8 GB  | Intel HD          | DNS/DHCP Server |
| hsb8      | i5-2415M 2.3GHz | 4       | 8 GB  | Intel HD          | Parents' Server |

**imac0 has the most CPU threads** (16), making it ideal for parallel Nix builds.

---

## Useful Commands

```bash
# home-manager rebuild
cd ~/Code/nixcfg
home-manager switch --flake ".#markus@imac0"

# System info
system_profiler SPHardwareDataType
sw_vers

# Disk usage
df -h / /nix /System/Volumes/Data

# Network
ifconfig en0
ping hsb0.lan

# Nix
nix flake check
nix-store --gc

# Homebrew
brew update && brew upgrade && brew cleanup
```

---

## Related Documentation

### In This Repository

- [Repository README](../../docs/README.md) - NixOS configuration guide
- [How It Works](../../docs/how-it-works.md) - Architecture and machine inventory

### Configuration Files

- [home.nix](./home.nix) - Main home-manager configuration
- [config/karabiner.json](./config/karabiner.json) - Keyboard remapping

### Related Hosts

- [gpc0 README](../gpc0/README.md) - Gaming PC (NixOS)
- [hsb0 README](../hsb0/README.md) - DNS/DHCP server
- [hsb1 README](../hsb1/README.md) - Home automation server

### Local Documentation

- [Progress & History](docs/progress.md) - Migration status & complete history
- [Manual Setup Guides](docs/manual-setup/) - One-time configuration steps
- [Technical Reference](docs/reference/) - Deep dives into specific features

---

## Changelog

### 2025-11-30: Detailed Hardware Documentation

- ✅ Added comprehensive Quick Reference table
- ✅ Added detailed Hardware Specifications section
- ✅ Added Nix Build Capabilities section
- ✅ Added Features table (F00-F08)
- ✅ Added Performance Comparison with other hosts
- ✅ Added Related Documentation section

### 2025-11-15: Migration Complete

- ✅ All configurations declaratively managed via Nix
- ✅ Shell (Fish), Terminal (WezTerm), Prompt (Starship)
- ✅ Git dual identity (personal/work)
- ✅ Karabiner-Elements declarative configuration
- ✅ ~700MB freed from Homebrew migration

---

**Last Updated**: November 30, 2025  
**Maintainer**: Markus Barta  
**Repository**: <https://github.com/markus-barta/nixcfg>

**For complete migration history and technical details, see [docs/progress.md](docs/progress.md)**
