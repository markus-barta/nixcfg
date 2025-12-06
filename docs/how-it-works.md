# How This Nix Configuration Works

> **Fork Attribution**: This configuration is a fork of Patrizio's (pbek) excellent NixOS setup. The core "hokage" module system originates from that work and is imported externally from `github:pbek/nixcfg`.

## The Big Picture

Think of this repository as a **blueprint factory** for all your computers. Instead of manually installing software and tweaking settings on each machine, you write down what you want in configuration files, and Nix makes it happen exactly as specified—every time, on every machine.

---

## Your Infrastructure at a Glance

This configuration manages your entire computing environment:

**Home Servers:**

- **hsb0** (192.168.1.99) - DNS/DHCP server running AdGuard Home
- **hsb1** (192.168.1.101) - Home automation hub with Node-RED, MQTT, HomeKit, VLC kiosk, UPS monitoring
- **hsb8** - Home automation server at parents' home

**Cloud Servers:**

- **csb0** (cs0.barta.cm) - Smart home automation hub with Node-RED, Mosquitto MQTT, Telegram bot (garage door control)
- **csb1** (cs1.barta.cm) - Monitoring & docs with Grafana, InfluxDB (fed by csb0 MQTT), Docmost, Paperless

**Workstations:**

- **imac0** - macOS development machine (managed via Home Manager)
- **gpc0** - AMD-powered gaming rig with Steam and Plasma desktop

---

## Architecture Overview

### Module Layers

This configuration uses a **layered architecture** with two complementary module systems:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                           HOST CONFIGURATION                               │
│                    hosts/hsb1/configuration.nix                            │
│   Sets hokage.role, uzumaki options, host-specific services                │
└────────────────────────┬───────────────────────────┬───────────────────────┘
                         │                           │
        ┌────────────────▼────────────────┐ ┌────────▼──────────────────────┐
        │         UZUMAKI MODULE          │ │       EXTERNAL HOKAGE         │
        │      modules/uzumaki/           │ │   github:pbek/nixcfg          │
        │                                 │ │                               │
        │  "Son of Hokage" 🌀             │ │  "Village Leader" 🍥          │
        │  • Fish functions (pingt, etc.) │ │  • User management            │
        │  • StaSysMo system monitoring   │ │  • System roles               │
        │  • Tokyo Night theming          │ │  • Core programs (git, ssh)   │
        │  • Per-host color palettes      │ │  • ZFS, networking            │
        │  • Zellij configuration         │ │  • Catppuccin theming         │
        └────────────────────────────────-┘ └───────────────────────────────┘
                         │                           │
        ┌────────────────▼───────────────────────────▼───────────────────────┐
        │                       modules/common.nix                            │
        │        Shared config for ALL NixOS systems                          │
        │   Loads AFTER hokage to override settings (fish, zellij, theme)    │
        └────────────────────────────────────────────────────────────────────┘
```

### Hokage: The Foundation 🍥

**Hokage** (火影, "Fire Shadow") comes from _Naruto_ where it's the title for the village leader. Just as the Hokage governs and protects the village, this module governs your NixOS configurations.

Hokage is imported **externally** from `github:pbek/nixcfg` and provides:

- **Roles**: Pre-configured sets of software and settings
  - `server-home` - For home servers (hsb0, hsb1, hsb8)
  - `server-remote` - For cloud servers (csb0, csb1)
  - `desktop` - For workstations with GUI (gpc0)
- **Programs**: Application configurations (git, openssh, atuin, etc.)
- **Languages**: Development environments (javascript, php, go, cplusplus)
- **Features**: ZFS, audio, networking, secrets management

#### Browsing Hokage Source

To explore hokage's implementation:

```bash
# Reference copy alongside your repo
~/Code/pbek-nixcfg/modules/hokage/

# Or use the multi-root workspace (opens both repos in one window)
cursor ~/Code/nixcfg/nixcfg.code-workspace

# View available options
just hokage-options
```

### Uzumaki: Personal Touch 🌀

**Uzumaki** (うずまき, "spiral") is named after the Uzumaki clan from _Naruto_, masters of sealing techniques—fitting for a module that seals in your personal configuration.

Uzumaki is the **local module** in `modules/uzumaki/` that builds on hokage's foundation:

- **Fish Functions**: `pingt` (timestamped ping), `stress`, `helpfish`, `sourcefish`
- **StaSysMo**: System monitoring in Starship prompt (CPU, RAM, Load, Swap)
- **Tokyo Night Theme**: Overrides hokage's Catppuccin with per-host color gradients
- **Zellij**: Terminal multiplexer with themed keybindings

### How They Work Together

```nix
# In hosts/hsb1/configuration.nix:

imports = [
  ./hardware-configuration.nix
  ../../modules/uzumaki      # Local: fish, stasysmo, theming
];

# Uzumaki: Personal tooling
uzumaki = {
  enable = true;
  role = "server";
  stasysmo.enable = true;    # System metrics in prompt
};

# Hokage: System foundation (imported via flake.nix)
hokage = {
  hostName = "hsb1";
  role = "server-home";
  zfs.enable = true;
  audio.enable = true;       # For VLC kiosk
};
```

---

## Complete Architecture Flow

When you run `nixos-rebuild switch --flake .#hsb1`:

```text
flake.nix
  │
  ├─→ Fetches external inputs:
  │     • nixpkgs (unstable)
  │     • home-manager
  │     • agenix (secrets)
  │     • disko (disk management)
  │     • nixcfg (hokage module from github:pbek/nixcfg)
  │
  ├─→ Applies overlays (stable + unstable package sets)
  │
  └─→ nixpkgs.lib.nixosSystem "hsb1"
        │
        ├─→ commonServerModules
        │     ├─→ home-manager
        │     ├─→ modules/common.nix (shared config)
        │     └─→ agenix (secrets)
        │
        ├─→ inputs.nixcfg.nixosModules.hokage (external)
        │     └─→ Provides: roles, programs, system setup
        │
        ├─→ hosts/hsb1/configuration.nix
        │     ├─→ hardware-configuration.nix
        │     ├─→ disk-config.zfs.nix
        │     ├─→ modules/uzumaki (fish, stasysmo, theme)
        │     └─→ Host-specific services
        │
        └─→ disko.nixosModules.disko (ZFS disk management)
```

---

## Repository Structure

| Directory/File         | Purpose                                   |
| ---------------------- | ----------------------------------------- |
| **flake.nix**          | Entry point, defines all hosts & inputs   |
| **hosts/**             | Per-machine configurations                |
| **modules/uzumaki/**   | Personal tooling module (fish, stasysmo)  |
| **modules/common.nix** | Shared config for all NixOS systems       |
| **overlays/**          | Package customizations, stable/unstable   |
| **pkgs/**              | Custom packages (qownnotes, nixbit, etc.) |
| **secrets/**           | Encrypted secrets (agenix .age files)     |
| **lib/**               | Utility functions                         |
| **tests/**             | NixOS integration tests                   |

### Host Configuration Structure

Each host folder contains:

```text
hosts/hsb1/
├── configuration.nix         # Main config (imports uzumaki, sets hokage)
├── hardware-configuration.nix # Auto-generated hardware details
├── disk-config.zfs.nix       # Declarative ZFS disk layout
├── secrets/                  # Host-specific encrypted secrets
├── tests/                    # Host-specific test scripts
└── README.md                 # Host documentation
```

### Uzumaki Module Structure

```text
modules/uzumaki/
├── default.nix        # Entry point, fish functions
├── options.nix        # Configuration options
├── common.nix         # Shared NixOS config
├── server.nix         # Server-specific config
├── desktop.nix        # Desktop-specific config
├── macos.nix          # macOS Home Manager support
├── fish/              # Fish shell functions
│   ├── functions.nix  # pingt, stress, helpfish, sourcefish
│   └── config.nix     # Shell aliases and abbreviations
├── stasysmo/          # System monitoring daemon
│   ├── nixos.nix      # NixOS service definition
│   ├── daemon.sh      # Background metrics collector
│   └── reader.sh      # Starship custom command
└── theme/             # Tokyo Night theming
    ├── theme-hm.nix       # Home Manager theme module
    ├── theme-palettes.nix # Per-host color definitions
    └── starship-template.toml
```

---

## Real-World Examples

### hsb0 - DNS & DHCP Server

```nix
hokage = {
  hostName = "hsb0";
  role = "server-home";     # ← Server preset with Fish, SSH, ZFS
  zfs.hostId = "1234abcd";
};

services.adguardhome = {
  enable = true;
  port = 3000;
  settings.dns.upstream_dns = [ "1.1.1.1" "1.0.0.1" ];
};
```

### hsb1 - Smart Home Hub

```nix
uzumaki = {
  enable = true;
  role = "server";
  stasysmo.enable = true;   # CPU/RAM in prompt
};

hokage = {
  hostName = "hsb1";
  role = "server-home";
  audio.enable = true;      # For VLC audio to HomePod
};

services.apcupsd.enable = true;  # UPS monitoring
hardware.flirc.enable = true;    # IR remote receiver
```

### imac0 - macOS Development Machine

Uses Home Manager to manage user environment:

```nix
programs.fish.enable = true;
programs.git = {
  user.email = "markus@barta.com";
  includes = [
    { condition = "gitdir:~/Code/BYTEPOETS/";
      contents.user.email = "markus.barta@bytepoets.com"; }
  ];
};
```

### gpc0 - Gaming Desktop

```nix
hokage = {
  hostName = "gpc0";
  role = "desktop";
  gaming.enable = true;     # Steam, gamemode, etc.
};

uzumaki = {
  enable = true;
  role = "desktop";
};
```

---

## Essential Commands

The repository uses `just` (a command runner) to simplify common tasks.

### Core Workflows

```bash
just check              # Validate configuration syntax
just switch             # Build and deploy to current machine
just upgrade            # Update flake inputs and rebuild
just rollback           # Revert to previous generation
just cleanup            # Free up disk space
```

### Remote Deployment

```bash
just hsb0-switch        # Deploy to hsb0
just hsb1-switch        # Deploy to hsb1
just csb0-switch        # Deploy to csb0
just csb1-switch        # Deploy to csb1
```

### Secrets Management (agenix)

```bash
just encrypt-file hosts/HOSTNAME/filename  # Encrypt sensitive file
just decrypt-file secrets/filename.age     # Decrypt for editing
just rekey                                 # Rekey after adding hosts
```

### Testing

```bash
just check-host HOSTNAME  # Validate specific host
just build-vm HOST        # Build VM for testing
just boot-vm              # Boot the VM
```

### Quick SSH Access

Fish shell abbreviations:

- `qc0` → SSH into hsb0 with zellij
- `qc1` → SSH into hsb1 with zellij
- `qcsb0` → SSH into csb0 with zellij
- `qcsb1` → SSH into csb1 with zellij

---

## Key Concepts

### Declarative Configuration

You don't install software by running commands. Instead, you **declare** what should be installed:

```nix
hokage.role = "server-home";
services.adguardhome.enable = true;
```

Nix reads this and ensures the system matches exactly.

### Reproducibility

The same configuration produces the **exact same system** every time. All dependencies are pinned in `flake.lock`.

### Layered Module System

1. **Hokage** (external) - Heavy lifting: users, roles, core programs
2. **Uzumaki** (local) - Personal touch: fish functions, theming
3. **common.nix** - Shared overrides applied after hokage
4. **Host config** - Machine-specific services and settings

### Theme Overrides (Tokyo Night)

Uzumaki overrides hokage's Catppuccin theming with Tokyo Night:

| Component    | Hokage Default   | Uzumaki Override       |
| ------------ | ---------------- | ---------------------- |
| **Starship** | Catppuccin       | Per-host Tokyo Night   |
| **Zellij**   | Catppuccin       | Per-host accent colors |
| **Helix**    | catppuccin_mocha | tokyonight_storm       |
| **Eza**      | Catppuccin       | Tokyo Night sysop      |
| **bat**      | Catppuccin       | tokyonight_night       |

---

## Terminology

### Core Nix Concepts

- **Flake**: Modern Nix project with `flake.nix` defining inputs and outputs
- **Module**: Reusable configuration piece (like a plugin)
- **Service**: Background process declared with `services.<name>.enable = true`
- **Package**: Software from nixpkgs, installed via `environment.systemPackages`

### Infrastructure Terms

- **Derivation**: Recipe for building something (reproducible)
- **Store**: `/nix/store/` where all built packages live
- **Generation**: Snapshot of system configuration (rollback-friendly)
- **Channel**: Version of nixpkgs (unstable, 25.05, etc.)
- **Home Manager**: Tool to manage user-specific configuration

---

## Why This Approach?

**For Your Setup:**

- **Home Lab**: hsb0 (DNS) and hsb1 (automation) share config but have unique services
- **Cloud**: csb0 and csb1 managed consistently via hokage
- **Development**: macOS uses same Fish config as NixOS machines
- **One Source of Truth**: All infrastructure in one Git repo
- **Disaster Recovery**: Reinstall + point to repo = restored system
- **Safe Experimentation**: Try changes, roll back if broken

**General Benefits:**

- No configuration drift
- Atomic updates (complete or nothing)
- Multi-machine consistency
- Encrypted secrets with agenix
- Time machine for infrastructure (boot previous generations)

---

## Related Documentation

- **NixOS Manual**: https://nixos.org/manual/nixos/stable/
- **Just Manual**: https://just.systems/man/en/
- **agenix**: https://github.com/ryantm/agenix
- **Disko (ZFS)**: https://github.com/nix-community/disko
- **Home Manager**: https://github.com/nix-community/home-manager

---

_This is a living system: declare what you want, Nix ensures it exists. Pure, reproducible infrastructure as code._
