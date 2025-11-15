# Hosts Directory

This directory contains configuration for all managed hosts (NixOS and macOS systems).

---

## Ownership & Organization

### MBA Hosts (Markus Barta)

**Personal Machines**:

- `imac-mba-home` - Home iMac 27" (macOS, home-manager)
  - Main development machine
  - Suffix indicates there are multiple iMacs in household
- `gaming-pc-mba` - Gaming PC (NixOS)
  - High-performance gaming machine
  - Suffix allows for potential second gaming PC

**Servers - Local** (Shared Infrastructure):

- `msww87` - MiniServer WW87 (NixOS)
  - Location: Father's house (remote location)
  - Purpose: Home automation server (similar to miniserver24 + miniserver99 combined)
  - Status: Running, planned for updates based on miniserver24/99 improvements
  - Setup: Based on friend's suggestions, to be modernized
- `miniserver24` - Server with restic backups to Hetzner (NixOS)
- `miniserver99` - DNS/DHCP Server with AdGuard Home (NixOS)
  - Network infrastructure
  - Serves entire household/network

**Servers - Cloud** (Netcup VPS):

- `csb0` - Cloud Server Barta 0 (NixOS) ⚠️ _Not yet in repo_
  - Netcup VPS
  - Backups to Hetzner storage
- `csb1` - Cloud Server Barta 1 (NixOS) ⚠️ _Not yet in repo_
  - Hostname: cs1.barta.cm
  - IP: 152.53.64.166
  - Netcup VPS 1000 G11 (Vienna)
  - Backups to Hetzner storage
  - Connect via: qc1

**Backup Infrastructure**:

- Hetzner Storage Box - Restic backup target
  - Used by: miniserver24, csb0, csb1

### Other Household

- `imac-mai` - Mailina's iMac, managed by mba (macOS)

### Pbek Hosts (Repository Owner/Friend)

**Work Machines (TU)**:

- `dp01` through `dp09` - Various work PCs and laptops
- `caliban` - TU Work PC
- `sinope` - TU HP EliteBook Laptop 840 G5
- `eris` - TU HP EliteBook Laptop 820 G4

**Personal Machines**:

- `gaia` - Office Work PC
- `venus` - Livingroom PC
- `rhea` - Asus Vivobook Laptop
- `hyperion` - Acer Aspire 5 Laptop
- `jupiter` - Asus Laptop
- `neptun` - MacBook
- `pluto` - PC Garage
- `mercury` - Desktop
- `ally` - Asus ROG Ally (Windows)
- `ally2` - Asus ROG Ally (NixOS)

**Servers**:

- `home01` - Home Server
- `moobox01` - Server for Alex
- `netcup01` - Netcup Server
- `netcup02` - Netcup Server
- `astra` - TUG VM

**Templates**:

- `vm-desktop` - Desktop VM template
- `vm-server` - Server VM template

---

## Naming Conventions

### Principle: Minimalism with Purpose

**Device Type First**: `{device-type}-{identifier}`

- Examples: `imac-*`, `gaming-pc-*`, `miniserver*`

**User/Owner Suffix**: Only when disambiguation is needed

- ✅ `imac-mba-home` - There are multiple iMacs (imac-mai)
- ✅ `gaming-pc-mba` - Potential for multiple gaming PCs
- ❌ `mba-server-*` - Servers are shared infrastructure, no owner prefix needed

**Servers**: Clean names without owner prefixes

- Servers serve infrastructure, not tied to single user
- Examples: `miniserver99`, `msww87`, `home01`

### For New Hosts

**Personal Machines** (when multiples exist or expected):

```
{device-type}-{user}-{location/purpose}
Examples: imac-mba-home, imac-mba-work, laptop-mba-travel
```

**Servers** (shared infrastructure):

```
{purpose}{number} or {codename}
Examples: miniserver100, homeserver02, apollo
```

**Work Machines** (organizational context):

```
{location/org}{number} or {codename}
Examples: dp01, tu-laptop-01, office-desktop
```

---

## Quick Reference

### By Type

**macOS (home-manager)**:

- `imac-mba-home`
- `imac-mai`
- `neptun`

**NixOS Desktop**:

- `gaming-pc-mba`
- `gaia`, `venus`, `rhea`, `hyperion`, `mercury`, `pluto`, `jupiter`
- `ally2`, `caliban`, `sinope`, `eris`
- `dp01-dp09`

**NixOS Servers**:

- Local: `msww87`, `miniserver24`, `miniserver99`
- Cloud (MBA): `csb0`, `csb1` ⚠️ _Not yet in repo_
- Cloud (Pbek): `netcup01`, `netcup02`
- Other: `home01`, `moobox01`, `astra`

---

## Directory Structure

Each host directory typically contains:

```
{hostname}/
├── configuration.nix      # NixOS config (for NixOS hosts)
├── home.nix              # home-manager config (for macOS hosts)
├── hardware-configuration.nix  # Hardware-specific settings
├── disk-config.zfs.nix   # ZFS disk configuration (if using disko)
├── README.md             # Host-specific documentation
└── ...                   # Additional host-specific files
```

Special cases:

- macOS hosts (like `imac-mba-home`) use home-manager only (no `configuration.nix`)
- VM templates contain `vm.nix` configuration
- Some hosts have additional scripts, static configs, or documentation

---

## Pending Additions

### Cloud Servers (MBA)

The following cloud servers need to be added to the repository:

**csb0** - Cloud Server Barta 0

- Status: ⚠️ Configuration not yet in repo
- Location: Netcup VPS
- Backups: Hetzner storage (restic)
- Setup: Originally configured via nixos-anywhere
- TODO: Extract configuration and add to repo

**csb1** - Cloud Server Barta 1

- Status: ⚠️ Configuration not yet in repo
- Location: Netcup VPS 1000 G11 (Vienna)
- Hostname: cs1.barta.cm
- IP: 152.53.64.166
- FQDN: v2202407214994279426.bestsrv.de
- Connect via: qc1 abbreviation
- Backups: Hetzner storage (restic)
- Setup: Originally configured via nixos-anywhere
- TODO: Extract configuration and add to repo

**Tasks for Cloud Server Integration**:

1. Extract current NixOS configuration from live servers
2. Add `csb0` and `csb1` directories to `hosts/`
3. Migrate credentials from 1Password to encrypted secrets
4. Document backup configuration (Hetzner restic)
5. Add to `flake.nix` with proper host definitions
6. Test deployment workflow with nixos-anywhere

**Secrets Migration Strategy**:

- Current: Various credentials in 1Password (inconsistent)
- Target: Encrypted secrets in git via age/rage
- Keep minimal info in 1Password: Only root recovery passwords
- Move operational secrets (SSH keys, API tokens, etc.) to secrets management
- Document in `docs/reference/secrets-management.md`

---

## Related Documentation

- [Main Repository README](../README.md) - Repository overview and setup
- [Secrets Management Architecture](imac-mba-home/docs/reference/secrets-management.md) - Encryption and secrets strategy
- Individual host READMEs - Host-specific configuration and documentation
