# NixOS Configuration Overview

This document explains how the different NixOS configurations in this repository work together, using `miniserver24` as an example.

## Repository Summary

This is a personal NixOS configuration repository that manages:
- **40+ hosts** (desktops, laptops, servers, gaming devices)
- **Modular architecture** with the custom `hokage` module system
- **Declarative secrets** management with agenix
- **Custom packages** (qownnotes, nixbit, ghostty, etc.)
- **Automated workflows** using `just` command runner
- **ZFS storage** with disko for disk management

The repository owner also maintains some packages included here.

## Architecture Flow

```text
flake.nix
  ├─> mkServerHost "miniserver24"
  │     ├─> commonServerModules
  │     │     ├─> home-manager
  │     │     ├─> nixpkgs overlays
  │     │     └─> agenix (secrets)
  │     ├─> hosts/miniserver24/configuration.nix
  │     └─> disko (disk management)
  │
  └─> hosts/miniserver24/configuration.nix
        ├─> hardware-configuration.nix
        ├─> disk-config.zfs.nix
        └─> modules/hokage (custom module system)
              ├─> default.nix (core options)
              ├─> common.nix (base configuration)
              └─> server-mba.nix (server-specific config)
```

## 1. Entry Point: flake.nix

The `flake.nix` file is the main entry point that:

- Defines inputs (nixpkgs, home-manager, agenix, disko, plasma-manager, nixos-hardware, etc.)
- Creates overlays from the `overlays/` directory
- Provides helper functions `mkServerHost` and `mkDesktopHost`
- Declares all system configurations in `nixosConfigurations`
- Exposes utility functions via `lib-utils` (from `lib/utils.nix`)
- Provides both stable (nixos-25.05) and unstable (nixos-unstable) package sets

### Example: miniserver24 Definition

```nix
miniserver24 = mkServerHost "miniserver24" [ disko.nixosModules.disko ];
```

This creates a server configuration by:

1. Using `mkServerHost` with hostname "miniserver24"
2. Including common server modules:
   - home-manager (NixOS module)
   - nixpkgs overlays (stable and unstable package sets)
   - agenix (secrets management)
3. Loading `hosts/miniserver24/configuration.nix`
4. Adding the disko module for ZFS disk management
5. Passing special arguments (inputs, lib-utils) to all modules

## 2. Host Configuration: hosts/miniserver24/configuration.nix

This file contains the host-specific configuration:

```nix
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hokage
    ./disk-config.zfs.nix
  ];

  hokage = {
    hostName = "miniserver24";
    zfs.hostId = "dabfdb01";
    audio.enable = true;
    serverMba.enable = true;
  };

  # Host-specific services, packages, and settings
}
```

**Key components:**

- **hardware-configuration.nix**: Hardware-specific settings (auto-generated)
- **disk-config.zfs.nix**: ZFS disk layout managed by disko
- **modules/hokage**: Custom module system (see below)
- **hokage options**: High-level configuration switches

## 3. Hokage Module System: modules/hokage/

The `hokage` module is a custom abstraction layer that simplifies system configuration.

### Structure

```text
modules/hokage/
├── default.nix          # Core options definition
├── common.nix           # Base system configuration
├── server-mba.nix       # MBA server-specific settings
├── desktop.nix          # Desktop environment
├── gaming.nix           # Gaming-related packages
├── languages/           # Programming language environments
└── programs/            # Application-specific configs
```

### How it Works

**modules/hokage/default.nix** defines options like:

```nix
hokage = {
  hostName = "miniserver24";
  userLogin = "mba";
  role = "server-home";
  useInternalInfrastructure = false;
  serverMba.enable = true;
};
```

These options control which features are enabled across the system.

## 4. Common Configuration: modules/common.nix

This file provides base configuration for **all** systems (automatically imported by `modules/hokage/default.nix`):

- Shell setup (fish with modern aliases, bash)
- Essential CLI tools (eza, bat, ripgrep, fd, git, htop, helix, etc.)
- User account creation and locale settings
- Nix flakes and experimental features
- Home Manager integration
- Security hardening (sudo-rs, restic)
- Package management (nh with automatic cleanup)

## 5. How Everything Connects

When you run `nixos-rebuild switch --flake .#miniserver24`:

1. **flake.nix** loads the miniserver24 configuration
2. **mkServerHost** applies common server modules
3. **hosts/miniserver24/configuration.nix** is loaded, which:
   - Imports hardware and disk configuration
   - Imports the hokage module system
   - Sets hokage options
   - Adds host-specific services (APC UPS, VLC kiosk, etc.)
4. **modules/hokage/default.nix**:
   - Imports `common.nix` for base configuration
   - Imports role-specific modules (e.g., `server-mba.nix`)
   - Imports enabled language/program modules
5. **modules/common.nix** sets up:
   - User accounts based on `hokage.users`
   - System packages
   - Shell configuration
   - Home Manager settings

## 6. Key Configuration Layers

| Layer | Purpose | Example |
|-------|---------|---------|
| **flake.nix** | System declaration & inputs | Defines all hosts, overlays, stable/unstable pkgs |
| **hosts/\<hostname\>/** | Host-specific config | Network, services, hardware |
| **modules/hokage/** | Abstraction layer | Role-based feature switches |
| **modules/common.nix** | Base system config | Users, shells, core packages |
| **overlays/** | Package customizations | Custom or modified packages |
| **pkgs/** | Custom packages | In-house software (qownnotes, nixbit, etc.) |
| **lib/** | Helper functions | Utility functions (listNixFiles, etc.) |
| **tests/** | NixOS tests | Integration tests for packages |

## Example: Adding a New Server

To add a new server similar to miniserver24:

```nix
# 1. In flake.nix
newserver = mkServerHost "newserver" [ disko.nixosModules.disko ];

# 2. Create hosts/newserver/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hokage
    ./disk-config.zfs.nix
  ];

  hokage = {
    hostName = "newserver";
    serverMba.enable = true;
    # Add custom options
  };
}
```

This modular approach ensures consistency across systems while allowing host-specific customization.

## Desktop vs Server Configurations

### Desktop Hosts (`mkDesktopHost`)

Desktop configurations include additional modules:
- **plasma-manager**: KDE Plasma configuration via Home Manager
- **espanso-fix**: Text expander with capabilities fix
- Full desktop environment support

Common desktop hosts:
- **gaia**: Office Work PC
- **venus**: Livingroom PC
- **rhea**: Asus Vivobook Laptop
- **hyperion**: Acer Aspire 5 Laptop
- **ally2**: Asus ROG Ally (using NixOS)

Desktop systems typically use `hokage.role = "desktop"` with gaming, development, and graphics acceleration support.

Server configurations are minimal and headless, using `hokage.role = "server-home"` or `"server-remote"` for network services and monitoring.

## Example: miniserver99 (DNS/DHCP Server)

The repository includes `miniserver99`, a specialized DNS/DHCP server:

```nix
# flake.nix
miniserver99 = mkServerHost "miniserver99" [ disko.nixosModules.disko ];
```

**Key Features:**
- AdGuard Home for DNS filtering and DHCP
- Declarative static DHCP leases with automatic UI sync
- Minimal server with agenix secrets management

**Network:** IP `192.168.1.99/24`, DHCP range `192.168.1.201-254`

See `hosts/miniserver99/README.md` for deployment details.

---

## Custom Packages and Overlays

### Custom Packages (`pkgs/`)

The repository includes custom Nix packages (qownnotes, nixbit, ghostty, zen-browser, television, lact, etc.) not available in nixpkgs or with custom modifications.

### Overlays (`overlays/`)

Overlays modify or replace packages from nixpkgs, providing both stable and unstable package sets via `pkgs.stable.<package>` and `pkgs.unstable.<package>`.

### Package Management

```bash
# Update package releases
just qownnotes-update-release
just nixbit-update-release

# Run tests and generate docs
just test-qownnotes
just hokage-options-md-save
```

---

## Essential Commands

The repository uses `just` (a command runner) to simplify common tasks. Run `just --list` for all commands.

### Core Workflows

```bash
# Test configuration
just check

# Build and deploy
just switch

# Update flake inputs and rebuild
just upgrade

# Rollback if issues occur
just rollback

# Free up disk space
just cleanup
```

### Secrets Management

The repository uses **agenix** for declarative secret management with dual-key encryption (your SSH key + host key).

**Commands must be run from the repository root directory** - they will show clear error messages if run elsewhere.

**Key Concepts:**
- Files in `hosts/HOSTNAME/` are automatically encrypted to `secrets/filename-HOST.age`
- Encryption requires both user and host SSH keys for security
- Encrypted files are gitignored; plaintext files are never committed

```bash
# Encrypt sensitive files (creates .age file + updates .gitignore)
just encrypt-file hosts/HOSTNAME/filename

# Decrypt encrypted files (tries user key first, falls back to host key)
just decrypt-file secrets/filename.age

# Rekey secrets after adding new hosts
just rekey
```

**Security Features:**
- Validates encryption/decryption works immediately
- Warns about weak SSH keys (no passphrase)
- Creates backups before overwriting files
- Stages encrypted files for commit automatically

### Remote Builds & Testing

```bash
# Build on remote servers
just build-on-home01
just build-on-caliban

# VM testing
just build-vm HOST
just boot-vm
```

See `just --list` for complete command reference.

## Advanced Features

### Development Environments

The repository uses `devenv` for reproducible development environments. Development environments are defined in `devenv.nix` and `files/shells/`.

### Hokage Module Introspection

```bash
# Explore hokage options
just hokage-options
just hokage-options-interactive
just hokage-options-md-save
```

---

## Best Practices

### Configuration Management
- Always test before deploying: `just check` before `just switch`
- Use VM testing for major changes: `just build-vm` and `just boot-vm`
- Keep secrets encrypted: `just encrypt-file` for sensitive data
- Validate all hosts periodically: `just check-all`

### Git Workflow
- Never commit secrets - use `just encrypt-file` to create `.age` files
- Commit frequently - NixOS configurations are declarative and rollback-friendly
- Use descriptive commit messages for encrypted file backups

### System Administration
- Keep rollback options: `just rollback` allows instant reversion
- Monitor disk space: `just cleanup` frees up space
- Update regularly: `just upgrade` keeps systems current
- Check logs after updates: `just logs-current-boot` helps diagnose issues

### Adding New Hosts
1. Pick hostname and add to `flake.nix` nixosConfigurations
2. Create `hosts/HOSTNAME/configuration.nix`
3. Generate hardware config with `nixos-generate-config`
4. Configure ZFS if needed with `just zfs-generate-host-id`
5. Add SSH key to `secrets/secrets.nix` and run `just rekey`
6. Test with `just check-host HOSTNAME`
7. Deploy with `nixos-anywhere` or manual installation

---

## Related Documentation

- **NixOS Manual**: [https://nixos.org/manual/nixos/stable/](https://nixos.org/manual/nixos/stable/)
- **Just Manual**: [https://just.systems/man/en/](https://just.systems/man/en/)
- **agenix**: [https://github.com/ryantm/agenix](https://github.com/ryantm/agenix)
- **rage**: [https://github.com/str4d/rage](https://github.com/str4d/rage)
- **Disko (ZFS)**: [https://github.com/nix-community/disko](https://github.com/nix-community/disko)
- **nixos-anywhere**: [https://github.com/nix-community/nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
- **Home Manager**: [https://github.com/nix-community/home-manager](https://github.com/nix-community/home-manager)
- **plasma-manager**: [https://github.com/nix-community/plasma-manager](https://github.com/nix-community/plasma-manager)
- **nh (yet-another-nix-helper)**: [https://github.com/viperML/nh](https://github.com/viperML/nh)
