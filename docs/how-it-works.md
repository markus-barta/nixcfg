# How This Nix Configuration Works

_A Bird's Eye View_

> **Note**: This configuration is a fork of Patrizio's (pbek) excellent NixOS setup, adapted for Markus's infrastructure. The core architecture and "hokage" module system originate from that work.

## The Big Picture

Think of this repository as a **blueprint factory** for all your computers. Instead of manually installing software and tweaking settings on each machine, you write down what you want in configuration files, and Nix makes it happen exactly as specified—every time, on every machine.

## Your Infrastructure at a Glance

This configuration manages your entire computing environment:

**Home Servers:**

- **hsb0** (192.168.1.99) - DNS/DHCP server running AdGuard Home
- **hsb1** (192.168.1.101) - Home automation hub with Node-RED, MQTT, HomeKit, and UPS monitoring
- **hsb8** - Home automation server at parents' home

**Cloud Servers:**

- **csb0** (cs0.barta.cm) - Smart home automation hub with Node-RED, Mosquitto MQTT, Telegram bot (garage door control), Traefik (Bitwarden test-only, being decommissioned)
- **csb1** (cs1.barta.cm) - Monitoring & docs with Grafana, InfluxDB (fed by csb0 MQTT), Docmost, Paperless

**Workstations:**

- **imac0** - Your macOS development machine (managed via Home Manager)
- **gpc0** - AMD-powered gaming rig with Steam

## The Main Components

### 1. **flake.nix** - The Master Blueprint

This is the entry point, like a table of contents that says:

- **What external building blocks to use** (nixpkgs, home-manager, agenix, disko, etc.)
- **Which machines exist** (hsb0, hsb1, csb0, csb1, imac0, etc.)
- **What type each machine is** (desktop or server)

It's the conductor of the orchestra, pointing to all the other pieces.

### 2. **hosts/** - Individual Machine Configurations

Each subdirectory represents one physical computer or VM.

**Your Key Machines:**

- `hosts/hsb0/` - DNS & DHCP server (AdGuard Home)
- `hosts/hsb1/` - Smart home hub (Node-RED, MQTT, HomeKit, VLC kiosk, UPS)
- `hosts/csb0/` - Cloud automation server (NixOS with old mixins structure, needs hokage migration)
- `hosts/csb1/` - Cloud monitoring & docs (NixOS with external hokage pattern)
- `hosts/imac0/` - macOS development machine
- `hosts/gpc0/` - Gaming desktop

Each host folder contains:

- `configuration.nix` - What makes this machine unique
- `hardware-configuration.nix` - The hardware details (CPU, disk, network interfaces)
- `disk-config.zfs.nix` - Declarative disk partitioning (optional, for servers with ZFS)

### 3. **modules/hokage/** - Reusable Building Blocks

Instead of copying the same configuration to every machine, common functionality lives here.

**About "Hokage"**: This name comes from _Naruto_ (the Japanese anime/manga) where "Hokage" (火影, "Fire Shadow") is the title for the leader of the Hidden Leaf Village. Just as the Hokage governs and protects the village, this module system "governs" your NixOS configurations! 🍥

The hokage module provides:

- **Roles**: Pre-configured sets of software and settings
  - `desktop` - For workstations with GUI
  - `server-home` - For home servers (hsb0, hsb1)
  - `server-mba` - For your MBA-specific server configs
  - `server-remote` - For cloud servers (csb0, csb1)

- **Programs**: Individual application configurations
  - `git.nix` - Git setup with dual identities (personal & BYTEPOETS work)
  - `ghostty.nix` - Terminal emulator
  - `atuin.nix` - Shell history sync
  - `openssh.nix` - SSH configuration
  - etc.

- **Languages**: Development environment setups
  - `javascript.nix` - Node.js tools
  - `php.nix` - PHP development
  - `go.nix` - Go toolchain
  - `cplusplus.nix` - C++ development

Think of hokage as a menu where each machine picks what it wants by setting `hokage.role` and enabling specific features.

### 4. **pkgs/** - Custom Software Packages

Software not available in the standard Nix repository gets built here. Custom-built packages that aren't in nixpkgs yet or need specific versions.

### 5. **secrets/** - Encrypted Sensitive Data

Passwords, API keys, SSH keys, and other sensitive configuration stored safely using `agenix` (age encryption). Examples:

- MQTT broker credentials for hsb1
- AdGuard Home admin credentials for hsb0
- GitHub tokens and SSH keys
- Static DHCP leases for your network

These files end in `.age` and can only be decrypted by the specific machines that need them.

### 6. **overlays/** - Package Modifications

When you need to tweak or override packages from the standard Nix repository, overlays let you do that without forking the entire package set. This also provides access to both `stable` and `unstable` package sets side by side.

## How It All Flows Together

```
┌─────────────┐
│  flake.nix  │  ← You run: nixos-rebuild switch (NixOS) or home-manager switch (macOS)
└──────┬──────┘
       │
       ├──→ Fetches external inputs (nixpkgs, home-manager, agenix, disko, etc.)
       │
       ├──→ Applies overlays (custom package modifications, stable+unstable channels)
       │
       └──→ Builds machine configuration:
            │
            ├──→ Loads host-specific config (e.g., hosts/hsb1/configuration.nix)
            │    └──→ Imports hokage modules
            │         └──→ Enables programs, languages, features based on role
            │              Example: hokage.serverMba.enable = true
            │
            ├──→ Installs custom packages (from pkgs/)
            │
            ├──→ Decrypts needed secrets (from secrets/)
            │    Example: MQTT credentials for hsb1
            │
            └──→ Generates complete system configuration
                 └──→ System activates with everything exactly as specified
```

## Real-World Examples from Your Setup

### hsb0 - DNS & DHCP Server

```nix
hokage = {
  hostName = "hsb0";
  role = "server-home";     # ← Automatically enables Fish, SSH, ZFS, etc.
  zfs.hostId = "1234abcd";
};

services.adguardhome = {
  enable = true;
  port = 3000;
  settings = {
    dns.upstream_dns = [ "1.1.1.1" "1.0.0.1" ];
    # ... DHCP and filtering configuration
  };
};
```

The hokage module handles all the base server config, you just add the AdGuard Home specifics.

### hsb1 - Smart Home Hub

```nix
hokage = {
  hostName = "hsb1";
  serverMba.enable = true;   # ← Your MBA-specific server preset
  audio.enable = true;       # ← For VLC audio to HomePod
};

services.apcupsd.enable = true;  # UPS monitoring
hardware.flirc.enable = true;    # IR remote receiver
# Plus Node-RED, MQTT, VLC kiosk mode, HomeKit services...
```

One configuration file describes the entire smart home hub!

### imac0 - macOS Development Machine

Uses `home-manager` to manage user environment (not full system):

```nix
programs.fish.enable = true;
programs.git = {
  # Personal identity by default
  user.email = "markus@barta.com";
  # Work identity auto-switches for BYTEPOETS projects
  includes = [
    { condition = "gitdir:~/Code/BYTEPOETS/";
      contents.user.email = "markus.barta@bytepoets.com"; }
  ];
};
```

Manages CLI tools, shell config, fonts, WezTerm terminal—all declaratively!

### csb0 & csb1 - Cloud Servers

**csb0**: Running NixOS with the OLD `modules/mixins` structure. Needs migration to new hokage structure.

**csb1**: Running NixOS with external hokage consumer pattern (migration completed November 2025).

**Critical dependency**: csb1's InfluxDB receives IoT data from csb0's MQTT broker. Both servers share the same Hetzner backup repository, with csb0 managing cleanup for both.

## Key Concepts

### Declarative Configuration

You don't install software by running commands. Instead, you **declare** what should be installed:

```nix
hokage.role = "server-home";
services.adguardhome.enable = true;
```

Nix reads this and ensures the system matches it exactly.

### Reproducibility

The same configuration file produces the **exact same system** every time, anywhere. All dependencies are pinned to specific versions in `flake.lock`.

### Profiles and Roles

Rather than configuring each machine from scratch:

1. A machine chooses a **role** (desktop, server-home, etc.)
2. The role activates a preset collection of modules
3. The machine adds its unique tweaks on top

## Typical Workflow

1. **Edit a configuration** (e.g., add port forwarding rule to hsb1)
2. **Test locally** or build remotely:
   ```bash
   just check                    # Validate syntax
   nixos-rebuild dry-run        # See what would change
   ```
3. **Deploy**:
   ```bash
   just switch                  # Apply on current machine
   # OR for remote deployment:
   just hsb0-switch             # Deploy to hsb0
   ```
4. **Rollback if needed**: Nix keeps previous generations—you can always boot into an older working version

### Quick SSH Access

Your Fish shell has handy abbreviations:

- `qc0` → SSH into hsb0 with zellij
- `qc1` → SSH into hsb1 with zellij
- `qcsb0` → SSH into csb0 with zellij
- `qcsb1` → SSH into csb1 with zellij

## Why This Approach?

**For Your Setup Specifically:**

- **Home Lab**: hsb0 (DNS) and hsb1 (automation) share common configuration but have unique services
- **Cloud Infrastructure**: csb0 and csb1 managed under hokage structure
- **Development Machine**: Your macOS iMac uses the same Fish config, Git setup, and tools as your NixOS machines
- **One Source of Truth**: All network infrastructure in one Git repo
- **Disaster Recovery**: Lost a server? Reinstall NixOS, point it to this repo, done.
- **Safe Experimentation**: Want to test a new Node-RED setup? Try it, and roll back if it breaks
- **Documentation Built-In**: The config files ARE the documentation

**General Benefits:**

- **No Configuration Drift**: Servers stay exactly as defined
- **Atomic Updates**: Changes apply completely or not at all—no half-broken states
- **Multi-Machine Consistency**: Same Fish shell, same tools, everywhere
- **Encrypted Secrets**: No plain-text passwords in Git
- **Time Machine for Your Infrastructure**: Boot any previous version

## Common Terminology

### Core Nix Concepts

- **Flake**: A modern Nix project with a `flake.nix` file that declares:
  - **Inputs** (dependencies from other repos, like npm packages)
  - **Outputs** (what it produces: system configs, packages, etc.)
  - Think of it as `package.json` + build instructions in one file
  - Your entire nixcfg repo is one big flake!

- **Module**: A reusable piece of configuration that can be imported into other configs
  - Like a plugin or building block
  - Can define options (settings) and configuration (what to do with those settings)
  - Examples: `modules/hokage/audio.nix`, `modules/hokage/zfs.nix`
  - NixOS itself is built from hundreds of modules (networking, users, services, etc.)
  - You mix and match modules to build exactly the system you want

- **Service**: In NixOS, a long-running background process (daemon)
  - Declared with `services.<name>.enable = true;`
  - Examples: `services.adguardhome.enable`, `services.openssh.enable`
  - NixOS generates systemd service files automatically from these declarations
  - You never write systemd unit files manually—just enable the service!

- **Package**: A piece of software (application, library, tool)
  - Available in the Nix package repository (nixpkgs)
  - Install declaratively: `environment.systemPackages = [ pkgs.htop pkgs.git ];`
  - Each package is built in isolation and stored in `/nix/store/`

### Nix Infrastructure Terms

- **Derivation**: A recipe for building something (a package, a config file, anything)
  - Contains all the instructions and dependencies needed
  - Produces the same output every time (reproducible builds)

- **Store**: The `/nix/store/` directory where all built packages live
  - Each package gets a unique hash-based path
  - Multiple versions of the same package can coexist peacefully
  - Nothing ever gets "overwritten"—old versions stay until garbage collected

- **Generation**: A snapshot of your system configuration
  - Every time you run `nixos-rebuild switch`, you create a new generation
  - You can boot any previous generation from the boot menu
  - Like Time Machine for your entire OS configuration
  - Rollback is instant and safe

- **Channel**: A version of the Nix package repository
  - Like "stable" vs "beta" release tracks
  - Examples: `nixos-unstable` (bleeding edge), `nixos-24.05` (stable release)
  - This config uses unstable as default, with stable available via `pkgs.stable.<package>`

- **Home Manager**: Tool to manage user-specific configuration
  - Your dotfiles, user packages, shell config—all declarative
  - Works on NixOS and other Linux distros (even macOS!)
  - Used for `imac0` to manage your macOS environment

---

_This is a living system: as you declare what you want, Nix ensures it exists. No manual steps, no forgotten configuration changes—just pure, reproducible infrastructure as code._

---

## Fun Fact: The Hokage Namespace

**Where does "Hokage" come from?** The name comes from _Naruto_ (the Japanese anime/manga) where "Hokage" (火影, "Fire Shadow") is the title for the leader of the Hidden Leaf Village. Just as the Hokage governs and protects their village, this module system governs and protects your NixOS configurations across all machines! 🍥

This namespace keeps all your custom settings organized and prevents naming conflicts with standard NixOS options. It's accessed like:

```nix
hokage.role = "server-home";
hokage.userLogin = "mba";
hokage.hostName = "hsb0";
hokage.serverMba.enable = true;
hokage.audio.enable = true;
hokage.zfs.enable = true;
```

Different machines can pick and choose which hokage features they need, making configuration DRY (Don't Repeat Yourself). This modular approach means you configure common features once and reuse them across all your machines—whether it's hsb0 at home, csb0 in the cloud, or hsb8 at your parents' place. Change it once, deploy everywhere! 🍥
