# NixOS Configuration - Documentation Index

**Repository**: Personal NixOS infrastructure configuration  
**Maintainer**: Markus Barta  
**Based on**: [github:pbek/nixcfg](https://github.com/pbek/nixcfg)

---

## 📋 Executive Summary

This repository manages NixOS systems using a modular `hokage` architecture. Systems can either use the local hokage module or consume it externally from upstream. Key features include declarative secrets management with `agenix`, ZFS storage with `disko`, and automated deployment workflows.

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
├── overview.md                 # Architecture and design philosophy
├── hokage-options.md           # Complete hokage module reference (1400+ lines)
├── CI-CD-PIPELINE.md           # GitHub Actions and automation
└── private/                    # Private documentation (not in git)
    ├── PICK-UP-HERE.md         # Personal task tracking
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

### Production Servers (Markus)

#### hsb0 (formerly miniserver99)

**Role**: DNS/DHCP/AdGuard server at Markus' home  
**Hokage Pattern**: Local module (legacy)  
**Status**: ✅ Production, planned migration to external hokage

```
hosts/hsb0/
├── README.md                                    # Server documentation
├── configuration.nix                            # NixOS configuration
├── hardware-configuration.nix                   # Hardware specs
├── disk-config.zfs.nix                          # ZFS disk layout
├── MIGRATION-PLAN-HOKAGE.md                     # [✅ READY] Hokage migration plan
├── SSH-KEY-SECURITY-NOTE.md                     # SSH security documentation
└── archive/
    └── MIGRATION-PLAN-HOSTNAME [DONE].md        # Completed hostname migration
```

**Key Features**: AdGuard Home DNS/DHCP, static DHCP leases (agenix), ZFS storage

#### hsb8 (formerly msww87)

**Role**: Home automation server at parents' home  
**Hokage Pattern**: External consumer (reference implementation)  
**Status**: ✅ Production ready, currently in test mode at jhw22

```
hosts/hsb8/
├── README.md                                    # Server documentation (949 lines)
├── configuration.nix                            # NixOS config with hokage options
├── hardware-configuration.nix                   # Hardware specs
├── disk-config.zfs.nix                          # ZFS disk layout
├── enable-ww87.md                               # Location deployment guide
├── BACKLOG.md                                   # Future improvements
├── tests/                                       # Comprehensive test suite
│   ├── README.md                                # Test suite overview
│   ├── T00-nixos-base.{md,sh}                   # NixOS base system (5 tests)
│   ├── T01-dns-server.{md,sh}                   # DNS server (AdGuard)
│   ├── T02-ad-blocking.md                       # Ad blocking (manual)
│   ├── T03-dns-cache.md                         # DNS cache (manual)
│   ├── T04-dhcp-server.md                       # DHCP server (not implemented)
│   ├── T05-static-dhcp-leases.md                # Static leases (depends on T04)
│   ├── T06-web-ui.md                            # Web management interface
│   ├── T07-query-logging.md                     # DNS query logging
│   ├── T08-dns-rewrites.md                      # Custom DNS rewrites
│   ├── T09-ssh-access.{md,sh}                   # SSH + security (11 tests) ⭐
│   ├── T10-multi-user.{md,sh}                   # Multi-user access (5 tests)
│   ├── T11-zfs-storage.{md,sh}                  # ZFS storage (6 tests)
│   ├── T12-zfs-snapshots.{md,sh}                # ZFS snapshots (4 tests)
│   ├── T13-location-config.md                   # Location-based config
│   └── T14-deployment.md                        # One-command deployment
└── archive/                                     # Historical documentation
    ├── HOKAGE-MIGRATION-2025-11-21.md           # Completed hokage migration
    ├── POST-HOKAGE-MIGRATION-SSH-FIX.md         # SSH key security fix
    ├── PASSWORD-SUDO-MATRIX.md                  # Password/sudo analysis
    ├── PASSWORDLESS-SUDO-DEPLOYMENT.md          # Sudo deployment guide
    ├── RECOVERY-INSTRUCTIONS.md                 # SSH recovery procedures
    ├── SECURITY-ANALYSIS-SUDO.md                # Security considerations
    └── VALIDATION-REPORT-2025-11-22.md          # Final validation report
```

**Key Features**: Location-based config (jhw22/ww87), AdGuard Home, ZFS, external hokage consumer, SSH security with `lib.mkForce`, comprehensive test suite (15 features)

**Reference Implementation**: hsb8 serves as the blueprint for external hokage consumer pattern

#### miniserver24

**Role**: Home automation at Markus' home  
**Hokage Pattern**: Local module (legacy)  
**Status**: ✅ Production

```
hosts/miniserver24/
├── README.md                                    # Server documentation
├── configuration.nix                            # NixOS configuration
├── hardware-configuration.nix                   # Hardware specs
└── disk-config.zfs.nix                          # ZFS disk layout
```

### Production Servers (Remote - csb0/csb1)

#### csb0 & csb1

**Role**: Remote servers  
**Hokage Pattern**: Local module (OLD modules/mixins structure)  
**Status**: ✅ Production (257 days uptime on csb0), need migration

```
hosts/csb0/                                      # Same structure for csb1
├── README.md                                    # Server documentation
└── secrets/
    ├── BACKLOG.md                               # Future improvements
    ├── MIGRATION-PLAN.md                        # Migration documentation
    └── RUNBOOK.md                               # Operational procedures
```

**Note**: Both csb0 and csb1 need migration from mixins → external hokage consumer pattern (use hsb8 as reference)

### Desktop Systems

#### mba-gaming-pc

**Role**: Gaming PC at Markus' home  
**Hokage Pattern**: Local module  
**Status**: ✅ Production

```
hosts/mba-gaming-pc/
├── configuration.nix                            # NixOS configuration
├── hardware-configuration.nix                   # Hardware specs
└── disk-config.zfs.nix                          # ZFS disk layout
```

#### imac-mba-home

**Role**: MacBook Air (macOS with home-manager)  
**Pattern**: Home-manager only (not NixOS)  
**Status**: ✅ Production

```
hosts/imac-mba-home/
├── README.md                                    # Setup documentation
├── home.nix                                     # Home-manager configuration
├── config/
│   ├── karabiner.json                           # Keyboard customization
│   └── starship.toml                            # Shell prompt config
├── docs/                                        # Detailed documentation
│   └── [11 markdown files]
└── scripts/                                     # Helper scripts
    ├── host-user/                               # User scripts
    └── setup/                                   # Setup automation
```

### Archived Systems

```
hosts/archived/
├── ally/                                        # Archived: Ally device
├── ally2/                                       # Archived: Ally device 2
├── astra/                                       # Archived: Astra server
├── caliban/                                     # Archived: Caliban server
├── dp01-dp09/                                   # Archived: Developer machines
├── eris/                                        # Archived: Eris system
├── gaia/                                        # Archived: Gaia system
├── home01/                                      # Archived: Home server
├── hyperion/                                    # Archived: Hyperion server
├── jupiter/                                     # Archived: Jupiter system
├── mercury/                                     # Archived: Mercury server
├── moobox01/                                    # Archived: Moobox server
├── neptun/                                      # Archived: Neptun system
├── netcup01/                                    # Archived: Netcup VPS 1
├── netcup02/                                    # Archived: Netcup VPS 2
├── pluto/                                       # Archived: Pluto system
├── rhea/                                        # Archived: Rhea system
├── sinope/                                      # Archived: Sinope system
├── venus/                                       # Archived: Venus server
├── vm-desktop/                                  # Archived: Desktop VM
└── vm-server/                                   # Archived: Server VM
```

---

## 🎯 Hokage Patterns

This repository uses two patterns for hokage module consumption:

### Local Module (Legacy)

Used by: `hsb0`, `miniserver24`, `mba-gaming-pc`, `csb0`, `csb1`

- Hokage module from local `modules/` directory
- Implicit configuration via mixins
- Older pattern, maintained for compatibility

### External Consumer (Recommended)

Used by: `hsb8` ⭐

- Consumes hokage from `github:pbek/nixcfg`
- Explicit configuration (no hidden mixins)
- Better for systems not using pbek's internal infrastructure
- Reference: [hosts/hsb8/](./hosts/hsb8/)

**Migration Path**: hsb0 has a [ready migration plan](./hosts/hsb0/MIGRATION-PLAN-HOKAGE.md) to external consumer pattern

---

## 🔍 Finding Specific Information

### "I want to understand the architecture"

→ [docs/overview.md](./docs/overview.md) - Architecture and design philosophy  
→ [docs/hokage-options.md](./docs/hokage-options.md) - Complete hokage reference

### "I want to see a complete server example"

→ [hosts/hsb8/README.md](./hosts/hsb8/README.md) - Most comprehensive documentation (949 lines)  
→ [hosts/hsb8/tests/](./hosts/hsb8/tests/) - Test suite with 15 features

### "I want to understand secrets management"

→ [docs/overview.md](./docs/overview.md) - Agenix workflow  
→ [secrets/secrets.nix](./secrets/secrets.nix) - Secret definitions  
→ `just encrypt-file <file>` / `just decrypt-file <file>`

### "I want to deploy a system"

→ [README.md](./README.md) - Quick start and deployment methods  
→ `just switch` - Deploy current system  
→ `just check` - Validate configuration

### "I want to migrate a server to external hokage"

→ [hosts/hsb0/MIGRATION-PLAN-HOKAGE.md](./hosts/hsb0/MIGRATION-PLAN-HOKAGE.md) - Complete migration guide  
→ [hosts/hsb8/](./hosts/hsb8/) - Reference implementation  
→ [hosts/hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md](./hosts/hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md) - Completed migration report

### "I want to understand SSH security"

→ [hosts/hsb0/SSH-KEY-SECURITY-NOTE.md](./hosts/hsb0/SSH-KEY-SECURITY-NOTE.md) - SSH key security overview  
→ [hosts/hsb8/tests/T09-ssh-access.md](./hosts/hsb8/tests/T09-ssh-access.md) - SSH security testing  
→ [hosts/hsb8/configuration.nix](./hosts/hsb8/configuration.nix) - `lib.mkForce` SSH key override example

### "I want to test a server"

→ [hosts/hsb8/tests/README.md](./hosts/hsb8/tests/README.md) - Test suite overview  
→ `./tests/T*.sh` - Run automated tests  
→ Individual test documentation: `tests/T*.md`

---

## 📊 Documentation Statistics

- **Active Production Systems**: 6 (hsb0, hsb8, miniserver24, csb0, csb1, mba-gaming-pc, imac-mba-home)
- **Total Test Cases**: 31 automated tests (hsb8)
- **Documentation Files**: 100+ markdown files
- **Hokage Options**: 200+ configuration options documented

---

**Last Updated**: November 22, 2025  
**For Questions**: Check individual system README.md or [docs/](./docs/)
