# NixOS Configuration Documentation

This directory contains comprehensive documentation for the nixcfg repository.

## Documentation Index

### Getting Started

- **[README.md](../README.md)** - Main repository overview and quick start guide
- **[how-it-works.md](how-it-works.md)** - Complete architecture overview (hokage + uzumaki modules)
- **[pbek.md](../pbek.md)** - Original historical content and setup instructions

### Host-Specific Documentation

- **[hosts/hsb1/README.md](../hosts/hsb1/README.md)** - Home automation server
- **[hosts/hsb0/README.md](../hosts/hsb0/README.md)** - DNS/DHCP server

### Module System

- **External Hokage** (`github:pbek/nixcfg`) - System foundation: roles, user management, core programs
- **Local Uzumaki** (`modules/uzumaki/`) - Personal tooling: fish functions, theming, stasysmo

### Key Features

- **Layered Architecture**: External hokage + local uzumaki module system
- **Secrets Management**: Declarative encryption with `agenix`
- **ZFS Storage**: Declarative disk management with `disko`
- **Tokyo Night Theme**: Per-host color palettes overriding hokage's Catppuccin
- **Automated Workflows**: Streamlined deployment with `just` commands

## Essential Commands

```bash
just check      # Validate configuration
just switch     # Build and deploy
just upgrade    # Update inputs and rebuild
just cleanup    # Free disk space
```

For complete documentation, see [how-it-works.md](how-it-works.md).
