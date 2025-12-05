# nixcfg

Personal NixOS configuration managing home servers, cloud infrastructure, and development workstations—all from a single Git repository.

> Built on the excellent [hokage module system](https://github.com/pbek/nixcfg) by Patrizio Bekerle, extended with custom tooling and Tokyo Night theming. 🍥

## What This Does

**Manages 6 NixOS hosts + 2 macOS workstations:**

| Host      | Role                                      | Location      |
| --------- | ----------------------------------------- | ------------- |
| **hsb0**  | DNS/DHCP (AdGuard Home)                   | Home          |
| **hsb1**  | Smart Home Hub (Node-RED, MQTT, HomeKit)  | Home          |
| **hsb8**  | Home Automation                           | Parents' Home |
| **gpc0**  | Gaming Desktop (Steam, Plasma)            | Home          |
| **csb0**  | IoT Hub (MQTT, Telegram Bot)              | Cloud         |
| **csb1**  | Monitoring (Grafana, InfluxDB, Paperless) | Cloud         |
| **imac0** | Development Workstation                   | macOS         |

**Key Capabilities:**

- 🏗️ **Declarative Everything** — Systems defined in code, reproducible anywhere
- 🔐 **Encrypted Secrets** — Passwords, keys, and tokens secured with [agenix](https://github.com/ryantm/agenix)
- 💾 **ZFS Storage** — Declarative disk layouts with [disko](https://github.com/nix-community/disko)
- 🎨 **Tokyo Night Theme** — Consistent look across all terminals and tools
- 📦 **Custom Packages** — QOwnNotes, NixBit, and other in-house software
- ⚡ **One-Command Deploys** — `just switch` and you're done

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Host Configuration                       │
│              (hsb0, hsb1, gpc0, csb0, etc.)                 │
└──────────────────────────┬──────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────────────┐
│   Uzumaki 🌀  │  │  common.nix   │  │   External Hokage 🍥   │
│  (Personal)   │  │   (Shared)    │  │  github:pbek/nixcfg   │
│               │  │               │  │                       │
│ Fish functions│  │ Overrides &   │  │ Roles, users, core    │
│ Tokyo Night   │  │ customization │  │ programs, ZFS, SSH    │
│ StaSysMo      │  │               │  │                       │
└───────────────┘  └───────────────┘  └───────────────────────┘
```

**Hokage** provides the foundation. **Uzumaki** adds the personal touch.

## Quick Start

```bash
# Clone
git clone https://github.com/markus-barta/nixcfg.git && cd nixcfg

# Validate configuration
just check

# Deploy to current machine
just switch

# Deploy to remote host
just hsb1-switch
```

## Essential Commands

| Command         | Description                     |
| --------------- | ------------------------------- |
| `just check`    | Validate all configurations     |
| `just switch`   | Build and deploy locally        |
| `just upgrade`  | Update flake inputs and rebuild |
| `just rollback` | Revert to previous generation   |
| `just cleanup`  | Free disk space                 |

**Secrets:**

```bash
just encrypt-file hosts/HOSTNAME/secret.txt  # Encrypt
just decrypt-file secrets/secret.age         # Decrypt
just rekey                                   # Rekey after adding hosts
```

## Documentation

- **[How It Works](docs/how-it-works.md)** — Architecture overview, module system explained
- **[Hokage Options](docs/hokage-options.md)** — Complete configuration reference
- **[Host READMEs](hosts/)** — Per-host documentation and runbooks

## Repository Structure

```
nixcfg/
├── flake.nix              # Entry point, all host definitions
├── hosts/                 # Per-machine configurations
│   ├── hsb0/             # DNS/DHCP server
│   ├── hsb1/             # Smart home hub
│   ├── gpc0/             # Gaming desktop
│   └── ...
├── modules/
│   ├── common.nix        # Shared NixOS config
│   └── uzumaki/          # Personal tooling & theming
├── pkgs/                  # Custom packages
├── secrets/               # Encrypted secrets (.age files)
└── docs/                  # Documentation
```

## Why NixOS?

- **Reproducibility** — Same config = same system, every time
- **Atomic Updates** — Changes apply completely or not at all
- **Rollbacks** — Boot any previous generation from the menu
- **Infrastructure as Code** — Your config _is_ the documentation

---

_One repo to rule them all, one flake to find them, one switch to bring them all, and in the Nix store bind them._ 💍
