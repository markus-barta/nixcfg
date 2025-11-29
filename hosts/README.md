# Hosts Directory

This directory contains configuration for all managed hosts (NixOS and macOS systems).

---

## 🏗️ Configuration Architecture

### Summary

This repository uses a modular architecture where **NixOS servers** import the full hokage module system (with common.nix for shared configurations), while **macOS hosts** use standalone Home Manager with selective imports. All hosts share:

- **Fish shell** configuration via `modules/shared/fish-config.nix`
- **Per-host theming** via `modules/shared/theme-hm.nix` (Starship, Zellij, Eza)
- **Color palettes** defined in `modules/shared/theme-palettes.nix`

### How It Works

**NixOS hosts** (hsb0, hsb1, hsb8, etc.) follow a layered approach: the flake defines the system, which loads the host's `configuration.nix`, imports the hokage module from an external repository (`github:pbek/nixcfg`), which then loads `common.nix` for system-wide settings. `common.nix` imports `theme-hm.nix` which auto-applies host-specific colors.

**macOS hosts** (imac0, imac-mba-work) use a simpler path: the flake loads Home Manager with `home.nix`, which directly imports `theme-hm.nix` for theming and `fish-config.nix` for shell settings.

### Configuration Flow Chart

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                              FLAKE.NIX                                  │
│                    (Entry point for all systems)                        │
└────────────┬────────────────────────────────────────┬───────────────────┘
             │                                        │
    ┌────────▼────────┐                    ┌──────────▼─────────┐
    │  NIXOS HOSTS    │                    │   MACOS HOSTS      │
    │  (hsb0, hsb1,   │                    │   (imac0,          │
    │   hsb8)         │                    │    imac-mba-work)  │
    └────────┬────────┘                    └──────────┬─────────┘
             │                                        │
    ┌────────▼────────────────┐           ┌───────────▼──────────────┐
    │ hosts/*/                │           │ hosts/*/                 │
    │ configuration.nix       │           │ home.nix                 │
    │                         │           │ (Home Manager only)      │
    │ - Hardware config       │           │                          │
    │ - Disk config (ZFS)     │           │ - macOS-specific tools   │
    │ - Networking            │           │ - WezTerm, Karabiner     │
    │ - Host-specific options │           │ - GUI app linking        │
    └────────┬────────────────┘           └─────────┬────────────────┘
             │                                      │
             │ imports                              │ imports
             │                                      │
    ┌────────▼──────────────────┐                   │
    │ EXTERNAL HOKAGE MODULE    │                   │
    │ github:pbek/nixcfg        │                   │
    │                           │                   │
    │ modules/hokage/           │                   │
    │ - default.nix (core)      │                   │
    │ - programs/ (git, etc)    │                   │
    │ - languages/              │                   │
    │ - server-home.nix         │                   │
    └────────┬──────────────────┘                   │
             │                                      │
             │ imports                              │
             │                                      │
    ┌────────▼───────────────────┐                  │
    │ modules/common.nix         │                  │
    │                            │                  │
    │ - System packages          │                  │
    │ - User accounts            │                  │
    │ - Home Manager per-user    │                  │
    │ - theme.hostname = $host   │←─ passes hostname for theming
    └────────┬───────────────────┘                  │
             │                                      │
             │ imports                              │ imports
             │                                      │
    ┌────────▼──────────────────────────────────────▼───────────┐
    │                   SHARED MODULES                          │
    │                                                           │
    │  modules/shared/theme-hm.nix ◄─────────────────────────┐  │
    │    │                                                   │  │
    │    │ reads hostname, looks up palette                  │  │
    │    ▼                                                   │  │
    │  modules/shared/theme-palettes.nix                     │  │
    │    │                                                   │  │
    │    │ generates configs                                 │  │
    │    ▼                                                   │  │
    │  ┌──────────────────────────────────────────────────┐  │  │
    │  │ ~/.config/starship.toml  (per-host colors)       │  │  │
    │  │ ~/.config/zellij/config.kdl (per-host theme)     │  │  │
    │  │ ~/.config/eza/theme.yml (sysop-focused colors)   │  │  │
    │  └──────────────────────────────────────────────────┘  │  │
    │                                                        │  │
    │  modules/shared/fish-config.nix                        │  │
    │    - fishAliases (gitpl, gitc, ll, j, etc)             │  │
    │    - fishAbbrs (tmux→zellij, vim→hx)                   │  │
    └────────────────────────────────────────────────────────┘  │
```

### Per-Host Color Scheme

Each host automatically gets a unique color palette via `theme-hm.nix`:

```text
┌─────────────────────┐          ┌─────────────────────┐
│   CLOUD SERVERS     │          │    HOME SERVERS     │
│                     │          │                     │
│  csb0    ⬜ White   │          │  hsb0    🟨 Yellow  │  ← DNS/DHCP warning!
│  csb1    🔵 Blue    │          │  hsb1    🟢 Green   │  ← Automation
└─────────────────────┘          │  hsb8    🟠 Orange  │  ← Parents' home
                                 └─────────────────────┘
┌─────────────────────┐          ┌─────────────────────┐
│    WORKSTATIONS     │          │      GAMING         │
│                     │          │                     │
│  imac0       ⬜ lightGray │    │  pcg0    💜 Purple  │
│  imac-mba-work  ⬛ darkGray│   │  stm*    💗 Pink    │
└─────────────────────┘          └─────────────────────┘
```

**Features applied per-host:**

- **Starship prompt**: Powerline gradient in host color, root alert, sudo indicator
- **Zellij**: Theme matching Starship colors
- **Eza**: Tokyo Night + sysop-focused (bold executables, directories)
- **Directory path**: Pure white `#ffffff` for maximum visibility

### Key Differences: NixOS vs macOS

| Aspect                | NixOS Hosts                       | macOS Hosts                       |
| --------------------- | --------------------------------- | --------------------------------- |
| **Entry File**        | `configuration.nix`               | `home.nix`                        |
| **System Type**       | Full NixOS system                 | Home Manager only                 |
| **Hokage Module**     | ✅ Full import (external)         | ❌ Not imported                   |
| **common.nix**        | ✅ Auto-imported via hokage       | ❌ Not imported (NixOS-specific)  |
| **theme-hm.nix**      | ✅ Via common.nix                 | ✅ Direct import                  |
| **fish-config.nix**   | ✅ Via common.nix                 | ✅ Direct import                  |
| **Platform Specific** | ZFS, systemd, networking          | WezTerm, Karabiner, GUI app links |
| **Theming**           | Auto (hostname from NixOS config) | Auto (hostname from `$HOST`)      |

### Why This Architecture?

**DRY Principle**: Configuration defined once, used everywhere:

- Fish shell settings in `modules/shared/fish-config.nix`
- Color palettes in `modules/shared/theme-palettes.nix`
- Theme generation in `modules/shared/theme-hm.nix`

**Per-Host Theming**: Each host gets unique colors automatically:

- Add host to `hostPalette` map → done
- Starship, Zellij, Eza all themed consistently
- Visual identification: "Yellow prompt? You're on hsb0 (DNS/DHCP)!"

**Platform Separation**: NixOS-specific settings (systemd, ZFS) stay in `common.nix`, don't clutter macOS config

**External Hokage**: Using `github:pbek/nixcfg` as upstream allows MBA servers to benefit from Pbek's updates while maintaining local overrides

---

## 🍎 macOS Setup Guide

### Prerequisites

A fresh or existing macOS machine (Intel or Apple Silicon).

### Step 1: Install Nix

```bash
# Install Nix (multi-user, recommended)
sh <(curl -L https://nixos.org/nix/install)

# Restart your terminal, then verify
nix --version
```

### Step 2: Enable Flakes

```bash
# Create Nix config directory
mkdir -p ~/.config/nix

# Enable flakes and nix-command
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### Step 3: Clone This Repository

```bash
# Clone to standard location
git clone https://github.com/markus-barta/nixcfg ~/Code/nixcfg
cd ~/Code/nixcfg
```

### Step 4: Apply Home Manager Configuration

```bash
# First-time installation (bootstraps home-manager)
nix run home-manager -- switch --flake ".#markus@<hostname>"

# Example for work iMac:
nix run home-manager -- switch --flake ".#markus@imac-mba-work"

# Example for home iMac:
nix run home-manager -- switch --flake ".#markus@imac0"
```

### Step 5: Set Fish as Default Shell

```bash
# Add Nix fish to allowed shells (requires sudo)
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells

# Set as your default login shell
chsh -s ~/.nix-profile/bin/fish

# Restart terminal or run:
exec fish
```

### Step 6: Install Karabiner-Elements (Optional)

```bash
# Install via Homebrew
brew install --cask karabiner-elements

# Grant permissions:
# System Preferences → Security & Privacy → Privacy → Input Monitoring
# Enable "karabiner_grabber" and "Karabiner-Elements"
```

The Karabiner configuration is already managed by home-manager!

### Updating Configuration

After initial setup, use the simpler command:

```bash
cd ~/Code/nixcfg

# Pull latest changes
git pull

# Apply updates
home-manager switch --flake ".#markus@<hostname>"
```

### Available macOS Hosts

| Host            | Description                   | Command                                                |
| --------------- | ----------------------------- | ------------------------------------------------------ |
| `imac0`         | Home iMac (personal default)  | `home-manager switch --flake ".#markus@imac0"`         |
| `imac-mba-work` | Work iMac (BYTEPOETS default) | `home-manager switch --flake ".#markus@imac-mba-work"` |

### Troubleshooting

**"command not found: home-manager"** after first install:

```bash
# Use nix run for first-time setup
nix run home-manager -- switch --flake ".#markus@<hostname>"
```

**PATH issues after switch**:

```bash
# Restart shell
exec fish

# Or verify PATH
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

**Fonts not showing in Terminal.app**:

```bash
# Refresh font cache
killall fontd

# Fonts are symlinked to ~/Library/Fonts/
ls ~/Library/Fonts/ | grep -i hack
```

---

## 🏗️ Infrastructure Overview

### Unified Naming Scheme (2025)

**Pattern**: Consistent 3-4 letter codes with numbers for scalability

```text
SERVERS:
  csb0, csb1              ← Cloud Server Barta (Hetzner VPS)
  hsb0, hsb1, hsb8        ← Home Server Barta (local infrastructure)

WORKSTATIONS:
  imac0                   ← iMac (Markus, home)
  imac1                   ← iMac (Mai, home)
  mbp0                    ← MacBook Pro (Markus, personal - future)

GAMING:
  pcg0                    ← PC Gaming (Markus, NixOS)
  stm0, stm1              ← Steam Machines (family - future)
```

### Active Hosts

#### Cloud Servers (Remote VPS)

| Host   | Old Name | Location | Role            | IP/FQDN      | Theme | Status                  |
| ------ | -------- | -------- | --------------- | ------------ | ----- | ----------------------- |
| `csb0` | csb0     | Hetzner  | Smart Home Hub  | cs0.barta.cm | ⬜    | ✅ Active (257d uptime) |
| `csb1` | csb1     | Hetzner  | Monitoring/Docs | cs1.barta.cm | 🔵    | ✅ Active               |

#### Home Servers (Local Infrastructure)

| Host   | Old Name     | Location | Role       | IP            | Theme | Status          |
| ------ | ------------ | -------- | ---------- | ------------- | ----- | --------------- |
| `hsb0` | miniserver99 | Home     | DNS/DHCP   | 192.168.1.99  | 🟨    | ✅ **Migrated** |
| `hsb1` | miniserver24 | Home     | Automation | 192.168.1.101 | 🟢    | ✅ **Migrated** |
| `hsb8` | msww87       | Parents  | DNS/DHCP   | 192.168.1.100 | 🟠    | 🚚 At Location  |

#### Workstations (Personal Machines)

| Host            | Old Name (Config) | Owner  | IP            | Theme | Status          |
| --------------- | ----------------- | ------ | ------------- | ----- | --------------- |
| `imac0`         | imac-mba-home     | Markus | 192.168.1.150 | ⬜    | ✅ **Migrated** |
| `imac1`         | -                 | Mai    | 192.168.1.152 | -     | ⏳ Future       |
| `imac-mba-work` | -                 | Markus | -             | ⬛    | ✅ **Themed**   |
| `mbp0`          | -                 | Markus | -             | -     | ⏳ Future       |

#### Gaming Systems

| Host   | Old Name      | Owner  | IP            | Theme | Status               |
| ------ | ------------- | ------ | ------------- | ----- | -------------------- |
| `pcg0` | mba-gaming-pc | Markus | 192.168.1.154 | 💜    | 🔄 Migration pending |
| `stm0` | -             | Family | -             | 💗    | ⏳ Future            |
| `stm1` | -             | Family | -             | 💗    | ⏳ Future            |

---

## 📋 Migration Status

### Migration Strategy

**Guinea Pig Approach**: Start with lowest-risk systems, learn, then migrate critical infrastructure

| Priority | Host    | Risk Level  | Reason                               | Status     |
| -------- | ------- | ----------- | ------------------------------------ | ---------- |
| 1        | `hsb8`  | 🟢 Very Low | Fresh install, not in production     | 🚚 At ww87 |
| 2        | `hsb1`  | 🟡 Medium   | Home automation, but less critical   | ⏳ Next    |
| 3        | `hsb0`  | 🔴 High     | DNS/DHCP, 200+ days uptime, critical | ✅ Done    |
| 4        | `imac0` | 🟢 Low      | Workstation, DHCP+config rename      | ✅ Done    |
| 5        | `pcg0`  | 🟢 Low      | Gaming PC, non-critical              | ⏳ Next    |

### Why This Order?

1. 🚚 **hsb8** - Physically at ww87, awaiting config switch
2. ⏳ **hsb1** - Next: Apply lessons to production automation server
3. ✅ **hsb0** - Most critical (DNS/DHCP) migrated successfully (DONE)
4. ✅ **imac0** - Workstation config migrated (DONE)

---

## Ownership & Organization

### MBA Hosts (Markus Barta)

**Cloud Servers**:

- csb0, csb1 - Production cloud infrastructure (Netcup VPS)

**Home Servers**:

- hsb0, hsb1, hsb8 - Local infrastructure (DNS, DHCP, automation)

**Workstations**:

- imac0, imac1, imac-mba-work, mbp0 - Personal development machines

**Gaming**:

- pcg0, stm0, stm1 - Gaming systems

---

## Naming Conventions (2025 Scheme)

### Principle: Consistent, Scalable, Three-Letter Codes

**Pattern**: `{type-code}{number}`

### Server Naming

**Cloud Servers**: `csb{n}` - Cloud Server Barta

- Examples: `csb0`, `csb1`, `csb2`
- Location: Remote VPS (Hetzner, Netcup, etc.)

**Home Servers**: `hsb{n}` - Home Server Barta

- Examples: `hsb0`, `hsb1`, `hsb8`
- Location: Local infrastructure
- Number gaps allowed for logical grouping (hsb8 = parents' location)

### Workstation Naming

**Pattern**: `{device}{n}` - Descriptive device type + number

- `imac{n}` - iMac desktops (imac0, imac1)
- `mbp{n}` - MacBook Pro (mbp0)
- `mba{n}` - MacBook Air (mba0) - not to confuse with "mba" user!

### Gaming Naming

- `pcg{n}` - PC Gaming (pcg0)
- `stm{n}` - Steam Machines (stm0, stm1)

### Why This Scheme?

✅ **Immediate clarity**: `imac0` > `imac-mba-home` (shorter, clearer)  
✅ **Scalable**: Easy to add imac2, hsb3, etc.  
✅ **Consistent pattern**: Servers use 3-letter codes, workstations use descriptive names  
✅ **No conflicts**: Clear separation between device types  
✅ **Future-proof**: Room for expansion (hsb2-7, imac2-9, etc.)

---

## Quick Reference

### MBA Infrastructure (Markus Barta)

**Servers**:

```text
csb0, csb1    Cloud (Hetzner VPS, production smart home + monitoring)
hsb0          Home (DNS/DHCP, 192.168.1.99) [was: miniserver99]
hsb1          Home (Automation, 192.168.1.101) [was: miniserver24]
hsb8          Parents (DNS/DHCP, 192.168.1.100) [was: msww87]
```

**Workstations**:

```text
imac0         iMac 27" (Markus, home) [was: imac-mba-home]
imac1         iMac (Mai, home) [was: wz-imac-mpe]
imac-mba-work iMac (Markus, work/BYTEPOETS)
pcg0          Gaming PC (Markus) [was: mba-gaming-pc]
```

### Pbek Hosts (Repository Owner/Friend)

These hosts remain in the repository for reference and shared infrastructure learning.  
See archived hosts for full list of Pbek's machines

---

## Directory Structure

**Standard layout** (every host follows this pattern):

```text
{hostname}/
├── README.md                  # Main documentation (always in root)
├── configuration.nix          # NixOS config (NixOS hosts only)
├── home.nix                   # home-manager config (macOS hosts only)
├── hardware-configuration.nix # Hardware settings
├── disk-config.zfs.nix        # Disk/ZFS layout
│
├── docs/                      # All non-README documentation
│   ├── 📋 BACKLOG.md          # Current work tracking (emoji for sorting)
│   ├── enable-ww87.md         # Feature-specific guides
│   └── ...                    # Other docs
│
├── archive/                   # Completed migrations (DONE files only)
│   └── MIGRATION-xxx [DONE].md
│
├── tests/                     # Test suite
│   ├── README.md              # Test overview + tracking table
│   ├── T00-feature.md         # Manual test procedures
│   ├── T00-feature.sh         # Automated test scripts
│   └── ...                    # One pair per feature
│
├── examples/                  # Config examples & references
│   ├── docker-compose.yml
│   └── ...
│
├── config/                    # Host-specific configs (optional)
├── scripts/                   # Host-specific scripts (optional)
└── secrets/                   # Encrypted secrets (csb0/csb1 only)
```

**Key principles:**

- `README.md` always in root (main entry point)
- `docs/` for all other documentation (BACKLOG, guides, notes)
- `archive/` for completed work only (migration histories with [DONE] marker)
- `tests/` with paired manual (.md) + automated (.sh) files
- `examples/` for reference configs and templates
- `📋 BACKLOG.md` uses emoji prefix to stand out and sort first

---

## 🔄 Active Migrations

### Current: Unified Naming + External Hokage + Per-Host Theming (2025)

**Goal**: Standardize names + migrate to external hokage consumer pattern + apply per-host color themes

**Status**: ✅ Theming Complete for All Active Hosts

| Phase | Hosts                     | Status     | Naming | Theming |
| ----- | ------------------------- | ---------- | ------ | ------- |
| 1     | hsb8 (was msww87)         | 🚚 At ww87 | ✅     | ✅      |
| 2     | hsb1 (was miniserver24)   | ✅ Done    | ✅     | ✅      |
| 3     | hsb0 (was miniserver99)   | ✅ Done    | ✅     | ✅      |
| 4     | imac0 (was imac-mba-home) | ✅ Done    | ✅     | ✅      |
| 5     | imac-mba-work             | ✅ Done    | N/A    | ✅      |
| 6     | pcg0 (was mba-gaming-pc)  | ⏳ Pending | -      | -       |

**Includes**: Hostname rename, folder restructure, DHCP updates, external hokage pattern, per-host theming

**Theming**: All hosts now use `modules/shared/theme-hm.nix` for consistent Starship/Zellij/Eza colors

**See**: `{hostname}/archive/MIGRATION-xxx [DONE].md` for completed migrations

---

## 📦 Cloud Server Management

### csb0, csb1 Status

**Current State**: Running production workloads, configurations exist on servers

**Integration Strategy**:

1. Document current configurations (in secrets/ subdirectories)
2. Migrate to hokage external consumer pattern
3. No folder addition to main repo (keep as external consumers)
4. Maintain runbooks and migration plans in host secrets/

**Why Not in Main Repo**:

- Already running stable production workloads
- Use external hokage consumer pattern from `github:pbek/nixcfg`
- Configuration managed via private documentation
- Secrets managed via agenix
- Connection via SSH shortcuts (qc0, qc1)

---

## Related Documentation

- [Main Repository README](../README.md) - Repository overview
- Individual host READMEs - Host-specific documentation
