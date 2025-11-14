# NixOS Configuration Documentation

This directory contains comprehensive documentation for the nixcfg repository.

## Documentation Index

### Getting Started
- **[README.md](../README.md)** - Main repository overview and quick start guide
- **[overview.md](overview.md)** - Complete architecture overview and workflow documentation
- **[pbek.md](../pbek.md)** - Original historical content and setup instructions

### Host-Specific Documentation
- **[hosts/miniserver24/README.md](../hosts/miniserver24/README.md)** - Home automation server
- **[hosts/miniserver99/README.md](../hosts/miniserver99/README.md)** - DNS/DHCP server

### Key Concepts
- **Modular Architecture**: Custom `hokage` module system for role-based configuration
- **Secrets Management**: Declarative encryption with `agenix`
- **ZFS Storage**: Declarative disk management with `disko`
- **Automated Workflows**: Streamlined deployment with `just` commands

## Architecture Overview

The repository follows a layered architecture:

1. **flake.nix** - Entry point defining inputs and system configurations
2. **hosts/** - Host-specific configurations and hardware settings
3. **modules/hokage/** - Custom abstraction layer for role-based features
4. **modules/common.nix** - Base configuration shared across all systems
5. **overlays/** & **pkgs/** - Custom package definitions and modifications

## Essential Commands

```bash
# Test configuration
just check

# Build and deploy
just switch

# Update and rebuild
just upgrade

# Free disk space
just cleanup
```

For complete documentation, see [overview.md](overview.md).
