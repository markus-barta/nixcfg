# NixOS Configuration - Documentation Index

**Repository**: Personal NixOS infrastructure configuration  
**Maintainer**: Markus Barta  
**Based on**: [github:pbek/nixcfg](https://github.com/pbek/nixcfg)

---

## 📋 Executive Summary

This repository manages NixOS systems using a **layered module architecture**:

- **External Hokage** (`github:pbek/nixcfg`) - System foundation: roles, user management, core programs
- **Local Uzumaki** (`modules/uzumaki/`) - Personal tooling: fish functions, theming, stasysmo

Key features include declarative secrets management with `agenix`, ZFS storage with `disko`, Tokyo Night theming, and automated deployment workflows.

**Quick Actions**:

- 🚀 **Deploy a system**: `just switch`
- 🔍 **Check configuration**: `just check`
- 🔐 **Manage secrets**: `just encrypt-file <file>` / `just decrypt-file <file>`
- 📖 **Main README**: [README.md](./README.md)

---

## 📚 Documentation Tree

### General Documentation

```
docs/
├── README.md                   # Documentation overview
├── how-it-works.md             # Architecture (hokage + uzumaki modules)
├── hokage-options.md           # Complete hokage module reference (1400+ lines)
├── CI-CD-PIPELINE.md           # GitHub Actions and automation
└── private/                    # Private documentation (not in git)
    ├── secrets-inventory.md    # Secrets overview
    ├── secrets-migration-plan.md
    └── dns-barta-cm.md         # DNS configuration
```

### Secrets Management

```
secrets/
├── secrets.nix                 # Agenix secret definitions
├── BACKLOG.md                  # Future secret restructuring plans
└── *.age                       # Encrypted secret files
```

### Deployment & Automation

```
.shared/
└── common.just                 # Common justfile commands

.github/
└── workflows/
    └── check.yml               # CI/CD pipeline (NixOS checks)
```

---

## 🖥️ System Documentation

### Production Servers (Home)

#### hsb0

**Role**: DNS/DHCP/AdGuard server at Markus' home  
**Hokage Pattern**: External consumer  
**Status**: ✅ Production

```
hosts/hsb0/
├── README.md                                    # Server documentation
├── configuration.nix                            # NixOS configuration
├── hardware-configuration.nix                   # Hardware specs
├── disk-config.zfs.nix                          # ZFS disk layout
├── docs/
│   └── RUNBOOK.md                               # Operational procedures
└── archive/
    └── MIGRATION-PLAN-HOSTNAME [DONE].md        # Completed hostname migration
```

**Key Features**: AdGuard Home DNS/DHCP, static DHCP leases (agenix), ZFS storage

#### hsb1

**Role**: Home automation at Markus' home  
**Hokage Pattern**: External consumer + uzumaki  
**Status**: ✅ Production

```
hosts/hsb1/
├── README.md                                    # Server documentation
├── configuration.nix                            # NixOS configuration
├── hardware-configuration.nix                   # Hardware specs
├── disk-config.zfs.nix                          # ZFS disk layout
└── docs/
    └── RUNBOOK.md                               # Operational procedures
```

**Key Features**: Node-RED, Mosquitto MQTT, Home Assistant, Scrypted, VLC kiosk, UPS monitoring

#### hsb8

**Role**: Home automation server at parents' home  
**Hokage Pattern**: External consumer (reference implementation)  
**Status**: ✅ Production ready, deployed at jhw22

```
hosts/hsb8/
├── README.md                                    # Server documentation (1150 lines)
├── configuration.nix                            # NixOS config with hokage options
├── hardware-configuration.nix                   # Hardware specs
├── disk-config.zfs.nix                          # ZFS disk layout
├── docs/
│   └── RUNBOOK.md                               # Operational procedures
├── tests/                                       # Comprehensive test suite
│   ├── README.md                                # Test suite overview
│   ├── T00-nixos-base.{md,sh}                   # NixOS base system (5 tests)
│   ├── T01-dns-server.{md,sh}                   # DNS server (AdGuard)
│   ├── T09-ssh-access.{md,sh}                   # SSH + security (11 tests) ⭐
│   ├── T10-multi-user.{md,sh}                   # Multi-user access (5 tests)
│   ├── T11-zfs-storage.{md,sh}                  # ZFS storage (6 tests)
│   └── ...
└── archive/                                     # Historical documentation
```

**Key Features**: Location-based config (jhw22/ww87), AdGuard Home, ZFS, external hokage consumer, SSH security with `lib.mkForce`, agenix secret management, comprehensive test suite (19 features)

**Reference Implementation**: hsb8 serves as the blueprint for external hokage consumer pattern

### Production Servers (Cloud)

#### csb0

**Role**: Smart home automation hub (Node-RED, MQTT, Telegram bot)  
**Hokage Pattern**: External consumer  
**Status**: ✅ Production

```
hosts/csb0/
├── README.md                                    # Server documentation
├── configuration.nix                            # NixOS configuration
├── docs/
│   └── RUNBOOK.md                               # Operational procedures
└── secrets/                                     # Host-specific secrets
```

**Key Features**: Node-RED, Mosquitto MQTT, Telegram garage door control

#### csb1

**Role**: Monitoring & documentation (Grafana, InfluxDB, Paperless, Docmost)  
**Hokage Pattern**: External consumer  
**Status**: ✅ Production

```
hosts/csb1/
├── README.md                                    # Server documentation
├── configuration.nix                            # NixOS configuration
├── docs/
│   └── RUNBOOK.md                               # Operational procedures
└── secrets/                                     # Host-specific secrets
```

**Key Features**: Grafana dashboards, InfluxDB (fed by csb0 MQTT), Paperless, Docmost

### Desktop Systems

#### gpc0

**Role**: Gaming PC at Markus' home  
**Hokage Pattern**: External consumer  
**Status**: ✅ Production

```
hosts/gpc0/
├── README.md                                    # PC documentation
├── configuration.nix                            # NixOS configuration
├── hardware-configuration.nix                   # Hardware specs
└── disk-config.zfs.nix                          # ZFS disk layout
```

**Key Features**: Steam gaming, AMD graphics, KDE Plasma desktop

#### imac0

**Role**: macOS development machine  
**Pattern**: Home-manager only (not NixOS)  
**Status**: ✅ Production

```
hosts/imac0/
├── README.md                                    # Setup documentation
├── home.nix                                     # Home-manager configuration
├── config/
│   ├── karabiner.json                           # Keyboard customization
│   └── starship.toml                            # Shell prompt config
├── docs/                                        # Detailed documentation
└── scripts/                                     # Helper scripts
    ├── host-user/                               # User scripts
    └── setup/                                   # Setup automation
```

---

## 🎯 Module Architecture

This repository uses a **layered module system**:

### External Hokage 🍥

All hosts consume hokage from `github:pbek/nixcfg`:

- **Used by**: All NixOS hosts (hsb0, hsb1, hsb8, gpc0, csb0, csb1)
- **Provides**: Roles, user management, core programs, ZFS, networking
- **Configuration**: `hokage.role`, `hokage.hostName`, etc.

### Local Uzumaki 🌀

Personal tooling module in `modules/uzumaki/`:

- **Used by**: All hosts (NixOS and macOS)
- **Provides**: Fish functions (pingt, stress, helpfish), StaSysMo, Tokyo Night theming
- **Configuration**: `uzumaki.enable`, `uzumaki.role`, `uzumaki.stasysmo.enable`

### Module Hierarchy

```
Host Configuration
    ↓
modules/uzumaki/          (personal tooling, theming)
    ↓
modules/common.nix        (shared overrides, loads AFTER hokage)
    ↓
github:pbek/nixcfg        (external hokage foundation)
```

**Reference**: [docs/how-it-works.md](./docs/how-it-works.md)

---

## 🔍 Finding Specific Information

### "I want to understand the architecture"

→ [docs/how-it-works.md](./docs/how-it-works.md) - Architecture (hokage + uzumaki modules)  
→ [docs/hokage-options.md](./docs/hokage-options.md) - Complete hokage reference

### "I want to see a complete server example"

→ [hosts/hsb8/README.md](./hosts/hsb8/README.md) - Most comprehensive documentation (1150 lines)  
→ [hosts/hsb8/tests/](./hosts/hsb8/tests/) - Test suite with 19 features

### "I want to understand secrets management"

→ [docs/how-it-works.md](./docs/how-it-works.md) - Agenix workflow  
→ [secrets/secrets.nix](./secrets/secrets.nix) - Secret definitions  
→ `just encrypt-file <file>` / `just decrypt-file <file>`

### "I want to deploy a system"

→ [README.md](./README.md) - Quick start and deployment methods  
→ `just switch` - Deploy current system  
→ `just check` - Validate configuration

### "I want to migrate a server to external hokage"

→ [hosts/hsb8/](./hosts/hsb8/) - Reference implementation  
→ [hosts/hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md](./hosts/hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md) - Completed migration report

### "I want to understand SSH security"

→ [docs/SSH-KEY-SECURITY.md](./docs/SSH-KEY-SECURITY.md) - SSH key security for external hokage
→ [hosts/hsb8/tests/T09-ssh-access.md](./hosts/hsb8/tests/T09-ssh-access.md) - SSH security testing  
→ [hosts/hsb8/configuration.nix](./hosts/hsb8/configuration.nix) - `lib.mkForce` SSH key override example

### "I want to test a server"

→ [hosts/hsb8/tests/README.md](./hosts/hsb8/tests/README.md) - Test suite overview  
→ `./tests/T*.sh` - Run automated tests  
→ Individual test documentation: `tests/T*.md`

---

## 📊 Documentation Statistics

- **Active Production Systems**: 6 (hsb0, hsb1, hsb8, gpc0, csb0, csb1) + 2 macOS (imac0, imac-mba-work)
- **Total Test Cases**: 31 automated tests (hsb8)
- **Documentation Files**: 100+ markdown files
- **Hokage Options**: 200+ configuration options documented

---

**Last Updated**: December 2025  
**For Questions**: Check individual system README.md or [docs/](./docs/)
