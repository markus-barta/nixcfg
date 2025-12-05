# nixcfg

[GitHub](https://github.com/pbek/nixcfg)

Personal NixOS configuration repository with declarative infrastructure, custom packages, and automated deployment workflows.

> **Note**: This repository is a fork of [Patrizio Bekerle's (pbek) NixOS configuration](https://github.com/pbek/nixcfg). The hokage module system is imported externally from that repository.

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

### How It Works

The repository uses a **wrapper pattern** for secret paths:

```nix
# secrets.nix (root) - Wrapper that enables both path formats
let
  rules = import ./secrets/secrets.nix;  # Actual secret definitions
  prefixed = builtins.listToAttrs (
    map (name: {
      name = "secrets/${name}";           # Creates prefixed version
      value = builtins.getAttr name rules;
    }) (builtins.attrNames rules)
  );
in
rules // prefixed  # Merge both unprefixed and prefixed paths
```

This allows both path formats to work:

- Unprefixed: `"static-leases-hsb0.age"`
- Prefixed: `"secrets/static-leases-hsb0.age"` ✅ (recommended)

**Configuration**: `.agenix.toml` points to the root wrapper:

```toml
[default]
secrets = "secrets.nix"  # Root wrapper, not secrets/secrets.nix
```

### Basic Workflow

```bash
# Edit an encrypted secret
agenix -e secrets/static-leases-hsb0.age

# Encrypt a new file
just encrypt-file hosts/HOSTNAME/filename

# Decrypt for inspection
just decrypt-file secrets/filename.age

# Rekey all secrets after adding new hosts
just rekey
```

See [docs/how-it-works.md](docs/how-it-works.md) for detailed architecture and encryption documentation.

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

Used by: `hsb0`, `hsb1`

```nix
# flake.nix
hsb1 = nixpkgs.lib.nixosSystem {
  modules = commonServerModules ++ [
    ./hosts/hsb1/configuration.nix
    disko.nixosModules.disko
  ];
};
```

Configuration inherits hokage from local `modules/` directory.

### External Hokage Consumer (Recommended)

For consuming the hokage module from upstream, see [examples/hokage-consumer](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/README.md) documentation.

**Example**: `hsb8` configuration

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
