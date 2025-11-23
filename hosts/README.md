# Hosts Directory

This directory contains configuration for all managed hosts (NixOS and macOS systems).

---

## 🏗️ Configuration Architecture

### Summary

This repository uses a modular architecture where **NixOS servers** import the full hokage module system (with common.nix for shared configurations), while **macOS hosts** use standalone Home Manager with selective imports. Shared fish shell configurations (aliases, abbreviations) are now centralized in `modules/shared/fish-config.nix` to avoid duplication across platforms.

### How It Works

**NixOS hosts** (hsb0, hsb8, csb0, csb1, etc.) follow a layered approach: the flake defines the system, which loads the host's `configuration.nix`, imports the hokage module from an external repository (`github:pbek/nixcfg`), which then loads `common.nix` for system-wide settings. Both `common.nix` and macOS configurations share fish shell settings via `modules/shared/fish-config.nix`.

**macOS hosts** (imac0) use a simpler path: the flake loads Home Manager with `home.nix`, which directly imports shared configurations like `fish-config.nix` without the full hokage/common.nix stack since many NixOS-specific options don't apply to Darwin.

### Configuration Flow Chart

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                              FLAKE.NIX                                  │
│                    (Entry point for all systems)                        │
└────────────┬────────────────────────────────────────┬───────────────────┘
             │                                        │
             │                                        │
    ┌────────▼────────┐                    ┌──────────▼─────────┐
    │  NIXOS HOSTS    │                    │   MACOS HOSTS      │
    │  (hsb0, hsb8,   │                    │   (imac0)          │
    │   csb0, csb1)   │                    │                    │
    └────────┬────────┘                    └──────────┬─────────┘
             │                                        │
             │                                        │
    ┌────────▼────────────────┐           ┌───────────▼──────────────┐
    │ hosts/*/                │           │ hosts/imac0/             │
    │ configuration.nix       │           │ home.nix                 │
    │                         │           │ (Home Manager only)      │
    │ - Hardware config       │           │                          │
    │ - Disk config (ZFS)     │           │ - Fish shell config      │
    │ - Networking            │           │ - Starship prompt        │
    │ - Host-specific options │           │ - macOS-specific tools   │
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
    │ - programs/ (atuin, etc)  │                   │
    │ - languages/ (nodejs, go) │                   │
    │ - desktop.nix             │                   │
    │ - server-home.nix         │                   │
    └────────┬──────────────────┘                   │
             │                                      │
             │ imports                              │
             │                                      │
    ┌────────▼──────────────┐                       │
    │ modules/common.nix    │                       │
    │                       │                       │
    │ - System packages     │                       │
    │ - User accounts       │                       │
    │ - Locale/timezone     │                       │
    │ - Base shell config   │                       │
    │ - Home Manager setup  │                       │
    └────────┬──────────────┘                       │
             │                                      │
             │ imports                              │ imports
             │                                      │
    ┌────────▼──────────────────────────────────────▼───────────┐
    │          modules/shared/fish-config.nix                   │
    │                                                           │
    │  - fishAliases (gitpl, gitc, ll, j, etc)                  │
    │  - fishAbbrs (tmux→zellij, vim→hx, nano→micro)            │
    │                                                           │
    │  Shared by ALL systems (NixOS + macOS)                    │
    └───────────────────────────────────────────────────────────┘
```

### Key Differences: NixOS vs macOS

| Aspect                | NixOS Hosts                       | macOS Hosts                       |
| --------------------- | --------------------------------- | --------------------------------- |
| **Entry File**        | `configuration.nix`               | `home.nix`                        |
| **System Type**       | Full NixOS system                 | Home Manager only                 |
| **Hokage Module**     | ✅ Full import (external)         | ❌ Not imported                   |
| **common.nix**        | ✅ Auto-imported via hokage       | ❌ Not imported (NixOS-specific)  |
| **fish-config.nix**   | ✅ Via common.nix                 | ✅ Direct import                  |
| **Platform Specific** | ZFS, systemd, networking          | macOS tools, Homebrew integration |
| **Shared Config**     | Aliases, abbreviations, functions | Same via fish-config.nix          |

### Why This Architecture?

**DRY Principle**: Fish shell configuration defined once in `modules/shared/fish-config.nix`, used everywhere

**Platform Separation**: NixOS-specific settings (systemd, ZFS) stay in `common.nix`, don't clutter macOS config

**External Hokage**: Using `github:pbek/nixcfg` as upstream allows MBA servers to benefit from Pbek's updates while maintaining local overrides (like disabling atuin)

**Selective Imports**: macOS only imports what it needs (fish config, starship) without the full NixOS stack

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

| Host   | Old Name | Location | Role            | IP/FQDN      | Status                  |
| ------ | -------- | -------- | --------------- | ------------ | ----------------------- |
| `csb0` | csb0     | Hetzner  | Smart Home Hub  | cs0.barta.cm | ✅ Active (257d uptime) |
| `csb1` | csb1     | Hetzner  | Monitoring/Docs | cs1.barta.cm | ✅ Active               |

#### Home Servers (Local Infrastructure)

| Host   | Old Name     | Location | Role       | IP            | Status             |
| ------ | ------------ | -------- | ---------- | ------------- | ------------------ |
| `hsb0` | miniserver99 | Home     | DNS/DHCP   | 192.168.1.99  | ✅ **Migrated**    |
| `hsb1` | miniserver24 | Home     | Automation | 192.168.1.101 | 🔄 Migration ready |
| `hsb8` | msww87       | Parents  | DNS/DHCP   | 192.168.1.100 | 🚚 **At Location** |

#### Workstations (Personal Machines)

| Host    | Old Name (Config) | Old Name (Network) | Owner  | IP            | Status                |
| ------- | ----------------- | ------------------ | ------ | ------------- | --------------------- |
| `imac0` | imac-mba-home     | wz-imac-home-mba   | Markus | 192.168.1.150 | ✅ **Migrated**       |
| `imac1` | -                 | wz-imac-mpe        | Mai    | 192.168.1.152 | ⏳ Future (DHCP only) |
| `mbp0`  | -                 | -                  | Markus | -             | ⏳ Future             |

#### Gaming Systems

| Host   | Old Name      | Owner  | IP            | Status               |
| ------ | ------------- | ------ | ------------- | -------------------- |
| `pcg0` | mba-gaming-pc | Markus | 192.168.1.154 | 🔄 Migration pending |
| `stm0` | -             | Family | -             | ⏳ Future            |
| `stm1` | -             | Family | -             | ⏳ Future            |

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

- imac0, imac1, mbp0 - Personal development machines

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

### Current: Unified Naming + External Hokage (2025)

**Goal**: Standardize names + migrate to external hokage consumer pattern

**Status**: ✅ Nearly Complete (3/5 done)

| Phase | Hosts                     | Status     | Started | Completed |
| ----- | ------------------------- | ---------- | ------- | --------- |
| 1     | hsb8 (was msww87)         | 🚚 At ww87 | Nov 19  | Nov 23    |
| 2     | hsb1 (was miniserver24)   | ⏳ Pending | -       | -         |
| 3     | hsb0 (was miniserver99)   | ✅ Done    | Nov 21  | Nov 23    |
| 4     | imac0 (was imac-mba-home) | ✅ Done    | Nov 23  | Nov 23    |
| 5     | pcg0 (was mba-gaming-pc)  | ⏳ Pending | -       | -         |

**Includes**: Hostname rename, folder restructure, DHCP updates, external hokage pattern

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
