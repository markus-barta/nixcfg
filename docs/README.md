# NixOS Configuration Overview

This document explains how the different NixOS configurations in this repository work together, using `miniserver24` as an example.

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

- Defines inputs (nixpkgs, home-manager, agenix, disko, etc.)
- Creates overlays from the `overlays/` directory
- Provides helper functions `mkServerHost` and `mkDesktopHost`
- Declares all system configurations in `nixosConfigurations`

### Example: miniserver24 Definition

```nix
miniserver24 = mkServerHost "miniserver24" [ disko.nixosModules.disko ];
```

This creates a server configuration by:

1. Using `mkServerHost` with hostname "miniserver24"
2. Including common server modules (home-manager, overlays, agenix)
3. Loading `hosts/miniserver24/configuration.nix`
4. Adding the disko module for ZFS disk management

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
  useInternalInfrastructure = true;
  serverMba.enable = true;
};
```

These options control which features are enabled across the system.

## 4. Common Configuration: modules/common.nix

This file provides base configuration for **all** systems:

- Shell setup (fish, bash)
- Essential CLI tools (git, htop, ripgrep, etc.)
- User account creation
- Locale and timezone settings
- Nix flakes and experimental features
- Home Manager integration

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
| **flake.nix** | System declaration & inputs | Defines all hosts, overlays |
| **hosts/\<hostname\>/** | Host-specific config | Network, services, hardware |
| **modules/hokage/** | Abstraction layer | Role-based feature switches |
| **modules/common.nix** | Base system config | Users, shells, core packages |
| **overlays/** | Package customizations | Custom or modified packages |
| **pkgs/** | Custom packages | In-house software |

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

## Example: miniserver99 (DNS/DHCP Server)

The repository includes `miniserver99`, a specialized DNS/DHCP server:

```nix
# flake.nix
miniserver99 = mkServerHost "miniserver99" [ disko.nixosModules.disko ];
```

**Key Features:**

- **AdGuard Home**: Native NixOS service for DNS filtering and DHCP
- **Static DHCP Leases**: Declaratively configured in the gitignored file `hosts/miniserver99/static-leases.nix`; rebuilds must include `--override-input miniserver99-static-leases path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix`
- **Lease Sync**: A systemd `preStart` hook merges declarative leases into `/var/lib/private/AdGuardHome/data/leases.json`, removing any UI-created static entries
- **Secrets Management**: Uses `agenix` with private-only access (Markus's SSH key)
- **Minimal Surface**: No desktop environment, audio, or media services

**Network:**

- IP: `192.168.1.99/24`
- DHCP Range: `192.168.1.201` - `192.168.1.254`
- Web Interface: [http://192.168.1.99:3000](http://192.168.1.99:3000)

See `hosts/miniserver99/README.md` for detailed deployment and migration instructions.

---

## Justfile Commands Reference

The repository uses `just` (a command runner) to simplify common tasks. All commands work across macOS and NixOS.

### Quick Start

```bash
# View all available commands
just --list

# View commands in a specific group
just --list | grep agenix
just --list | grep build
```

### Installation

```bash
# NixOS (available in system by default if configured)
nix-shell -p just

# macOS
brew install just
```

---

### Encryption & Secrets (agenix group)

#### encrypt-file - Encrypt sensitive files

Encrypts any file in the `hosts/HOSTNAME/` directory structure using dual-key encryption (your SSH key + host key).

**Usage:**
```bash
just encrypt-file hosts/HOSTNAME/filename
```

**Examples:**
```bash
# Encrypt static DHCP leases
just encrypt-file hosts/miniserver99/static-leases.nix

# Encrypt API keys
just encrypt-file hosts/home01/api-keys.env

# Encrypt database credentials
just encrypt-file hosts/netcup01/db-config.conf
```

**Features:**
- Auto-detects hostname from path
- Uses local SSH key on Mac, reads from `secrets.nix` on servers
- Dual-key encryption (user + host keys)
- Validates encryption immediately
- Atomically updates `.gitignore`
- Stages files for commit

**Security Checks:**
- Warns if SSH key has no passphrase
- Warns if file exists in Git history
- Validates decryption works
- Creates timestamped backups

#### decrypt-file - Decrypt encrypted files

Decrypts an `.age` file back to plaintext.

**Usage:**
```bash
just decrypt-file ENCRYPTED_FILE [OUTPUT_FILE]
```

**Examples:**
```bash
# Auto-detect output location
just decrypt-file secrets/static-leases-miniserver99.age

# Specify output location explicitly
just decrypt-file secrets/api-keys-home01.age hosts/home01/api-keys.env
```

**Features:**
- Tries user key first (Mac), falls back to host key (servers)
- Auto-detects output path from filename pattern
- Creates backups before overwriting
- Works on both macOS and NixOS

---

### Build & Deploy (build group)

#### switch - Build and deploy

```bash
just switch
```

Builds and activates the NixOS configuration for the current host.

#### upgrade - Update and rebuild

```bash
just upgrade
```

Updates flake inputs and switches to new configuration.

#### build - Build current host

```bash
just build
```

Builds without activating (useful for testing).

#### check - Validate configuration

```bash
just check
```

Checks if configuration can be built successfully.

#### check-all - Validate all hosts

```bash
just check-all
```

Checks if all hosts defined in `flake.nix` can be built.

---

### Maintenance (maintenance group)

#### cleanup - Free up disk space

```bash
just cleanup
```

Performs system cleanup:
- Clears journal logs older than 3 days
- Prunes Docker system
- Empties trash
- Runs nix garbage collection
- Optimizes nix store

#### list-generations - Show system generations

```bash
just list-generations
```

Lists all system generations (rollback points).

#### rollback - Rollback to previous generation

```bash
just rollback
```

Rolls back to the previous NixOS generation.

---

### Common Workflows

#### Daily Development

```bash
# Make changes to configuration
nano hosts/miniserver99/configuration.nix

# Test the build
just check

# Apply changes
just switch
```

#### Updating Static Leases

```bash
# Edit leases
nano hosts/miniserver99/static-leases.nix

# Deploy to server
just switch

# Backup encrypted version to Git
just encrypt-file hosts/miniserver99/static-leases.nix
git commit -m "backup: update static leases"
git push
```

#### After Cloning Repo

```bash
# Decrypt your sensitive files
just decrypt-file secrets/static-leases-miniserver99.age

# Build and deploy
just switch
```

#### System Updates

```bash
# Update flake inputs and rebuild
just upgrade

# If issues occur, rollback
just rollback
```

---

### Additional Commands

For a complete list of available commands, run:
```bash
just --list
```

Common groups include:
- **agenix**: Encryption and secrets management
- **build**: Build and deploy operations
- **maintenance**: System cleanup and rollback
- **log**: Log viewing and monitoring
- **docs**: Documentation generation

---

## Related Documentation

- **NixOS Manual**: [https://nixos.org/manual/nixos/stable/](https://nixos.org/manual/nixos/stable/)
- **Just Manual**: [https://just.systems/man/en/](https://just.systems/man/en/)
- **agenix**: [https://github.com/ryantm/agenix](https://github.com/ryantm/agenix)
- **rage**: [https://github.com/str4d/rage](https://github.com/str4d/rage)
- **Disko (ZFS)**: [https://github.com/nix-community/disko](https://github.com/nix-community/disko)
- **nixos-anywhere**: [https://github.com/nix-community/nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
