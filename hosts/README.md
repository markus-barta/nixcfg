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

**Servers** (Shared Infrastructure):

- `msww87` - General purpose server (NixOS)
- `miniserver24` - Server (NixOS)
- `miniserver99` - DNS/DHCP Server with AdGuard Home (NixOS)
  - Network infrastructure
  - Serves entire household/network

### Other Household

- `imac-mai` - Mai's iMac (macOS)

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

- `msww87`, `miniserver24`, `miniserver99`
- `home01`, `moobox01`, `netcup01`, `netcup02`, `astra`

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

## Related Documentation

- [Main Repository README](../README.md) - Repository overview and setup
- Individual host READMEs - Host-specific configuration and documentation
