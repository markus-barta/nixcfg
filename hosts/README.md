# Hosts Directory

This directory contains configuration for all managed hosts (NixOS and macOS systems).

---

## 🏗️ Infrastructure Overview

### Unified Naming Scheme (2025)

**Pattern**: Consistent 3-4 letter codes with numbers for scalability

```
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

| Host   | Old Name     | Location | Role       | IP            | Status                 |
| ------ | ------------ | -------- | ---------- | ------------- | ---------------------- |
| `hsb0` | miniserver99 | Home     | DNS/DHCP   | 192.168.1.99  | 🔄 Migration pending   |
| `hsb1` | miniserver24 | Home     | Automation | 192.168.1.101 | 🔄 Migration pending   |
| `hsb8` | msww87       | Parents  | DNS/DHCP   | 192.168.1.100 | 🚀 **Migrating first** |

#### Workstations (Personal Machines)

| Host    | Old Name (Config) | Old Name (Network) | Owner  | IP            | Status                |
| ------- | ----------------- | ------------------ | ------ | ------------- | --------------------- |
| `imac0` | imac-mba-home     | wz-imac-home-mba   | Markus | 192.168.1.150 | 🔄 Migration pending  |
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

| Priority | Host    | Risk Level  | Reason                               | Status           |
| -------- | ------- | ----------- | ------------------------------------ | ---------------- |
| 1        | `hsb8`  | 🟢 Very Low | Fresh install, not in production     | 🚀 In Progress   |
| 2        | `hsb1`  | 🟡 Medium   | Home automation, but less critical   | ⏳ Next          |
| 3        | `hsb0`  | 🔴 High     | DNS/DHCP, 200+ days uptime, critical | ⏳ After hsb1    |
| 4        | `imac0` | 🟢 Low      | Workstation, DHCP+config rename      | ⏳ After servers |
| 5        | `pcg0`  | 🟢 Low      | Gaming PC, non-critical              | ⏳ After imac0   |

### Why This Order?

1. **hsb8** - Test naming + hokage pattern on fresh, non-critical system
2. **hsb1** - Apply lessons to production, but less critical than DNS
3. **hsb0** - Most critical (DNS/DHCP), migrate last with full confidence
4. **Workstations** - After infrastructure stable

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

```
csb0, csb1    Cloud (Hetzner VPS, production smart home + monitoring)
hsb0          Home (DNS/DHCP, 192.168.1.99) [was: miniserver99]
hsb1          Home (Automation, 192.168.1.101) [was: miniserver24]
hsb8          Parents (DNS/DHCP, 192.168.1.100) [was: msww87]
```

**Workstations**:

```
imac0         iMac 27" (Markus, home) [was: imac-mba-home]
imac1         iMac (Mai, home) [was: wz-imac-mpe]
pcg0          Gaming PC (Markus) [was: mba-gaming-pc]
```

### Pbek Hosts (Repository Owner/Friend)

These hosts remain in the repository for reference and shared infrastructure learning.  
See archived hosts for full list of Pbek's machines

---

## Directory Structure

Each host directory typically contains:

```
{hostname}/
├── configuration.nix         # NixOS config (for NixOS hosts)
├── home.nix                  # home-manager config (for macOS hosts)
├── hardware-configuration.nix # Hardware-specific settings
├── disk-config.zfs.nix       # ZFS disk configuration (if using disko)
├── README.md                 # Host-specific documentation
├── MIGRATION-PLAN.md         # Migration documentation (during transitions)
└── ...                       # Additional host-specific files
```

Special cases:

- macOS hosts (like `imac0`) use home-manager only (no `configuration.nix`)
- VM templates contain `vm.nix` configuration
- Migration hosts include `MIGRATION-PLAN.md` for tracking progress
- Server hosts may have secrets/ subdirectory for encrypted configs

---

## 🔄 Active Migrations

### Current: Unified Naming Scheme Migration (2025)

**Goal**: Standardize all host names to consistent, scalable pattern

**Status**: 🚀 In Progress

| Phase          | Hosts                     | Status         | Started | Completed |
| -------------- | ------------------------- | -------------- | ------- | --------- |
| 1. Guinea Pig  | hsb8 (was msww87)         | 🚀 In Progress | Nov 19  | -         |
| 2. Home Server | hsb1 (was miniserver24)   | ⏳ Pending     | -       | -         |
| 3. DNS/DHCP    | hsb0 (was miniserver99)   | ⏳ Pending     | -       | -         |
| 4. Workstation | imac0 (was imac-mba-home) | ⏳ Pending     | -       | -         |
| 5. Gaming      | pcg0 (was mba-gaming-pc)  | ⏳ Pending     | -       | -         |

**Migration Includes**:

- Hostname changes
- Folder renames in repository
- DHCP static lease updates
- macOS LocalHostName updates (workstations)
- Hokage external consumer pattern (servers)
- Documentation updates

**See**: Individual `MIGRATION-PLAN.md` files in each host directory for detailed plans

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

- [Main Repository README](../README.md) - Repository overview and setup
- [Secrets Management Architecture](imac-mba-home/docs/reference/secrets-management.md) - Encryption and secrets strategy
- Individual host READMEs - Host-specific configuration and documentation
