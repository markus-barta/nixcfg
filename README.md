# nixcfg

[GitHub](https://github.com/pbek/nixcfg)

Personal NixOS configuration repository managing multiple systems with declarative infrastructure, custom packages, and automated deployment workflows.

> **Note**: This repository was originally created by Patrizio Bekerle (pbek). For the original detailed setup instructions and historical content, see [pbek.md](pbek.md).

## System Inventory

### Production Servers

| Hostname     | Former Name  | Role             | Location     | Hokage Pattern | Status |
| ------------ | ------------ | ---------------- | ------------ | -------------- | ------ |
| hsb0         | miniserver99 | DNS/DHCP/AdGuard | Markus' home | Local module   | ✅     |
| hsb8         | msww87       | Home automation  | Parents'     | External       | ✅     |
| miniserver24 | -            | Home automation  | Markus' home | Local module   | ✅     |

### Desktop Systems

| Hostname      | Type        | Location     | Status |
| ------------- | ----------- | ------------ | ------ |
| mba-gaming-pc | Gaming PC   | Markus' home | ✅     |
| miniserver25  | MacBook Air | Portable     | ✅     |

**Hokage Pattern Legend**:

- **Local module**: Uses hokage from this repository's `modules/` directory
- **External**: Consumes hokage from `github:pbek/nixcfg` (recommended for new systems)

## Features

- **Modular Architecture**: Custom `hokage` module system for role-based configuration
- **Multi-Platform**: Desktop, laptop, and server configurations
- **Secrets Management**: Declarative encryption with `agenix`
- **Custom Packages**: In-house software (QOwnNotes, NixBit, Ghostty, etc.)
- **ZFS Storage**: Declarative disk management with `disko`
- **Automated Workflows**: Streamlined deployment with `just` commands
- **External Hokage Consumer**: Pattern for consuming hokage module from upstream

## Screenshots

### Shell Environment

![Shell](./screenshots/shell.png)

## Quick Start

1. **Clone the repository:**

   ```bash
   git clone https://github.com/pbek/nixcfg.git
   cd nixcfg
   ```

2. **Add your host configuration** to `flake.nix` and create `hosts/yourhostname/configuration.nix`

3. **Test your configuration:**

   ```bash
   just check
   ```

4. **Deploy:**
   ```bash
   just switch
   ```

For detailed setup instructions, see [docs/README.md](docs/README.md).

## Secrets Management

This repository uses [agenix](https://github.com/ryantm/agenix) for declarative secret encryption.

### Basic Workflow

```bash
# Encrypt a sensitive file
just encrypt-file hosts/HOSTNAME/filename

# Decrypt an encrypted file
just decrypt-file secrets/filename.age

# Rekey secrets after adding new hosts
just rekey
```

See [docs/overview.md](docs/overview.md) for detailed encryption documentation.

## Example Configurations

### Server with External Hokage Consumer

See [hosts/hsb8/README.md](hosts/hsb8/README.md) - Complete example of:

- External hokage module consumption from `github:pbek/nixcfg`
- Location-based configuration (multi-site deployment)
- AdGuard Home DNS/DHCP server
- ZFS storage management
- Comprehensive test suite (manual + automated)
- SSH key security with `lib.mkForce` overrides

### Server with Local Hokage Module

See [hosts/hsb0/README.md](hosts/hsb0/README.md) - Migration example:

- Local hokage module usage
- DNS/DHCP with AdGuard Home
- Static DHCP lease management with agenix
- Hostname migration documentation

## Installation Methods

### Remote Deployment (Recommended)

Deploy to new machines using [nixos-anywhere](https://github.com/nix-community/nixos-anywhere):

```bash
# Test in VM first
nix run github:nix-community/nixos-anywhere -- --flake .#hostname --vm-test

# Deploy to physical machine
nix run github:nix-community/nixos-anywhere -- --flake .#hostname root@target-ip
```

### Manual Installation

For manual setup with ZFS and encryption:

```bash
# Boot NixOS minimal ISO
# Partition and format disks
sudo nix --experimental-features nix-command --extra-experimental-features flakes \
  run github:nix-community/disko -- --mode disko ./hosts/hostname/disk-config.zfs.nix

# Install system
sudo nixos-install --flake .#hostname
```

## Hokage Module Patterns

This repository supports two patterns for using the hokage module system:

### Local Hokage Module (Legacy)

Used by: `hsb0`, `miniserver24`

```nix
# flake.nix
miniserver24 = mkServerHost "miniserver24" [ disko.nixosModules.disko ];
```

Configuration inherits hokage from local `modules/` directory.

### External Hokage Consumer (Recommended)

Used by: `hsb8`

```nix
# flake.nix
hsb8 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # Consume from upstream
    ./hosts/hsb8/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // { inherit inputs; };
};
```

```nix
# hosts/hsb8/configuration.nix
hokage = {
  hostName = "hsb8";
  userLogin = "mba";
  role = "server-home";
  useInternalInfrastructure = false;
  zfs.enable = true;
  users = [ "mba" "gb" ];
};

# Override hokage's SSH key injection
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # Your key only
  ];
};
```

**Benefits**:

- Always up-to-date with upstream hokage
- Explicit configuration (no hidden mixins)
- Better for servers not using pbek's internal infrastructure

See [hosts/hsb8/README.md](hosts/hsb8/README.md) for complete implementation.

---

See [hosts/hsb0/README.md](hosts/hsb0/README.md) for additional deployment examples.
