# hsb8 - Parents' Home Automation Server

**Mac mini 2011** (Intel i5-2415M) running NixOS for home automation at parents' home.

---

## Quick Reference

| Item                  | Value                                                                      |
| --------------------- | -------------------------------------------------------------------------- |
| **Hostname**          | `hsb8`                                                                     |
| **Model**             | Mac mini 2011                                                              |
| **CPU**               | Intel Core i5-2415M @ 2.30GHz (2 cores, 4 threads)                         |
| **RAM**               | 8 GB (7.7 GiB usable)                                                      |
| **Storage**           | 120 GB Kingston SV300S37A SSD (111.8 GB usable)                            |
| **Filesystem**        | ZFS (zroot pool, 7% used, compression enabled)                             |
| **Static IP**         | `192.168.1.100`                                                            |
| **MAC Address**       | `40:6c:8f:18:dd:24`                                                        |
| **Network Interface** | `enp2s0f0`                                                                 |
| **SSH Access**        | `ssh mba@192.168.1.100` or `ssh mba@hsb8.lan`                              |
| **Location**          | Currently at jhw22 (Markus' home), deployment target: ww87 (parents' home) |
| **Users**             | `mba` (admin), `gb` (Gerhard)                                              |
| **ZFS Host ID**       | `cdbc4e20`                                                                 |

---

## Features

Server capabilities and services (target configuration for ww87):

| ID  | Technical                 | User-Friendly Description                                 | Test |
| --- | ------------------------- | --------------------------------------------------------- | ---- |
| F00 | NixOS Base System         | Declarative configuration, reliable updates, reproducible | T00  |
| F01 | DNS Server (AdGuard Home) | Provides fast and reliable domain name resolution         | T01  |
| F02 | Ad Blocking               | Blocks ads and trackers across all devices on the network | T02  |
| F03 | DNS Cache                 | Speeds up internet by caching DNS responses               | T03  |
| F04 | DHCP Server               | Automatically assigns IP addresses to devices             | T04  |
| F05 | Static DHCP Leases        | Ensures devices always get the same IP address            | T05  |
| F06 | Web Management Interface  | Easy configuration through AdGuard Home web UI            | T06  |
| F07 | DNS Query Logging         | See what domains are being accessed (privacy-focused)     | T07  |
| F08 | Custom DNS Rewrites       | Redirect specific domains to custom addresses             | T08  |
| F09 | SSH Remote Access         | Secure remote server management from anywhere             | T09  |
| F10 | Multi-User Access         | Multiple users (Markus, Gerhard) can access the server    | T10  |
| F11 | ZFS Storage               | Reliable storage with data integrity checking             | T11  |
| F12 | ZFS Snapshots             | Automatic backups protect against data loss               | T12  |
| F13 | Location-Based Config     | Automatically adapts to home or parents' location         | T13  |
| F14 | One-Command Deployment    | Switch locations with a single command (`enable-ww87`)    | T14  |
| F15 | Docker & Home Assistant   | Home automation platform running in Docker for gb user    | T15  |
| F16 | User Identity Config      | Correct git authorship and user information               | T16  |
| F17 | Fish Shell Utilities      | sourcefish function and EDITOR=nano for convenience       | T17  |
| F18 | Local /etc/hosts          | Privacy-focused hostname resolution without DNS           | T18  |
| F19 | Agenix Secret Management  | Encrypted secrets (DHCP leases) managed securely          | T19  |

**Test Documentation**: See [tests/](./tests/) directory for detailed test procedures and automated scripts. Each feature has a corresponding test ID (Txx) that validates functionality.

**Note**: F15 (Home Assistant) will run under gb user account and requires manual setup of Docker Compose configuration.

---

## Current Status

✅ **Deployed and Running** (November 22, 2025)

- **Location**: `jhw22` (testing at Markus' home)
- **Static IP**: `192.168.1.100` configured
- **Repository**: Successfully switched from pbek/nixcfg to markus-barta/nixcfg
- **Configuration**: Using **external hokage consumer pattern** from `github:pbek/nixcfg`
- **SSH Keys**: Explicitly configured (mba + gb only, NO external access)
- **Secret Management**: Agenix configured with encrypted DHCP static leases (27 devices)
- **AdGuard Home**: Ready to activate at parents' home (currently disabled)
- **DHCP Server**: Disabled by default for safety

⚠️ **CRITICAL**: After reboot on Nov 22, SSH lockout occurred. Fix applied using `lib.mkForce` to override hokage's default SSH keys. Physical access required to deploy fix.

**Ready for deployment**: Run `enable-ww87` when machine is moved to parents' home.

---

## Table of Contents

1. [Location-Based Configuration](#location-based-configuration)
2. [One-Command Deployment (enable-ww87)](#one-command-deployment-enable-ww87)
3. [Hardware Specifications](#hardware-specifications)
4. [Network Configuration](#network-configuration)
5. [User Accounts](#user-accounts)
6. [Services](#services)
7. [Secret Management with Agenix](#secret-management-with-agenix)
8. [System Management](#system-management)
9. [Historical Context](#historical-context)
10. [Troubleshooting](#troubleshooting)

---

## Location-Based Configuration

The hsb8 server uses a **location-based configuration** that adapts network settings and services based on physical location.

### Available Locations

| Location | Name          | Gateway     | DNS               | Search Domain | AdGuard Home |
| -------- | ------------- | ----------- | ----------------- | ------------- | ------------ |
| `jhw22`  | Markus' home  | 192.168.1.5 | 192.168.1.99      | lan           | Disabled     |
| `ww87`   | Parents' home | 192.168.1.1 | 127.0.0.1 (local) | local         | Enabled      |

### How It Works

The location is set in `hosts/hsb8/configuration.nix`:

```nix
location = "jhw22"; # <-- CHANGE THIS WHEN MOVING MACHINE
```

Based on this variable, the configuration automatically adjusts:

- Default gateway
- DNS servers
- Search domain
- AdGuard Home service (enabled/disabled)
- Firewall rules

### Safety Features

- **Assertion validation**: Ensures location is either "jhw22" or "ww87"
- **Conditional logic**: Only enables services when appropriate
- **No manual network editing**: All changes handled declaratively

---

## One-Command Deployment (enable-ww87)

### Overview

The `enable-ww87` command is a one-step solution for switching the server from testing (jhw22) to production (ww87) configuration.

**See**: [enable-ww87.md](./enable-ww87.md) for complete documentation.

### Usage

**Prerequisites for deployment to parents' home:**

- ✅ Server physically at parents' home
- ✅ Connected to parents' network
- ✅ Physical/console access required (remote SSH won't work with wrong gateway)

**At the physical server console:**

```bash
# Log in as mba at the console
# Run the deployment script
enable-ww87
```

The script will:

1. ✅ Change location from "jhw22" → "ww87"
2. ✅ Apply configuration via `nixos-rebuild switch` (network reconfigures)
3. ✅ Commit and push changes to Git (after network is working)
4. ✅ Enable AdGuard Home (DNS + web UI)
5. ✅ Update network settings automatically
6. ✅ Show status and next steps

**Important**: Configuration is applied BEFORE committing/pushing to ensure the network gateway is correct for Git operations.

**After deployment**, remote access works:

```bash
ssh mba@192.168.1.100
```

### What It Does NOT Do

- ❌ Does NOT enable DHCP server (left disabled for safety)
- ❌ Does NOT change static IP (remains 192.168.1.100)

### After Deployment

- **AdGuard Home Web UI**: http://192.168.1.100:3000
- **Default Credentials**: admin / admin
- **DNS Service**: Running on port 53
- **DHCP**: Disabled (enable manually when ready)

### Enabling DHCP Server

When ready to enable the DHCP server at parents' home:

```bash
# Edit configuration
nano ~/nixcfg/hosts/hsb8/configuration.nix

# Find line (around line 113):
#   enabled = false;  # TODO: Enable when ready

# Change to:
#   enabled = true;

# Commit and deploy
cd ~/nixcfg
git add hosts/hsb8/configuration.nix
git commit -m "feat(hsb8): enable DHCP server"
git push
nixos-rebuild switch --flake .#hsb8

# Verify
systemctl status adguardhome
ss -ulnp | grep :67
```

### Reverting to jhw22

To switch back to Markus' home configuration (requires physical access at Markus' home):

```bash
# At physical console
cd ~/nixcfg
nano hosts/hsb8/configuration.nix
# Change: location = "ww87" → location = "jhw22"

# Apply first (network reconfigures)
nixos-rebuild switch --flake .#hsb8

# Then commit/push
git add hosts/hsb8/configuration.nix
git commit -m "feat(hsb8): revert to jhw22 location"
git push
```

---

## Hardware Specifications

### System Details

- **Model**: Mac mini 2011 (Intel-based)
- **CPU**: Intel Core i5-2415M @ 2.30GHz
  - 2 cores, 4 threads (2 threads per core)
  - Sandy Bridge architecture (2nd generation)
- **RAM**: 8 GB DDR3 (7.7 GiB usable)
- **Storage**: Kingston SV300S37A120G
  - **Type**: SSD (Solid State Drive)
  - **Capacity**: 120 GB (111.8 GB usable)
  - **Interface**: SATA
  - **Status**: Non-rotating (ROTA=0), confirmed SSD
- **Network**: Gigabit Ethernet (enp2s0f0)
- **Wireless**: Broadcom adapter (driver available, currently unused)

### Software

- **OS**: NixOS 25.11 (Xantusia)
- **Kernel**: Linux 6.17.8
- **Architecture**: x86_64 GNU/Linux
- **ZFS Host ID**: `cdbc4e20`
- **Machine ID**: `94f5aa5a70c24ddf99c7903586a66606`

### Disk Layout

```
NAME     SIZE   TYPE  MOUNTPOINT        ROTA  MODEL
sda      111.8G disk                    0     KINGSTON SV300S37A120G
├─sda1   1M     part  (BIOS boot)       0
├─sda2   500M   part  /boot             0
└─sda3   111.3G part  (ZFS zroot)       0
zram0    3.8G   disk  [SWAP]            0
```

### ZFS Configuration

```
Pool: zroot
Size: 111 GB total
Allocated: 8.23 GB (7% used)
Free: 103 GB available
State: ONLINE (healthy)
Health: No known data errors
Disk: disk-disk1-zfs (111.3 GB)
Fragmentation: 1%
Dedup: 1.00x (disabled)
Compression: Enabled (lz4)

Filesystems:
- zroot/root  → /      (system root)
- zroot/nix   → /nix   (Nix store)
- zroot/home  → /home  (user data)
```

---

## Network Configuration

### Current Configuration (jhw22)

```
Interface: enp2s0f0
IP Address: 192.168.1.100/24 (static)
Gateway: 192.168.1.5 (vr-fritz-box)
DNS: 192.168.1.99 (miniserver99 / AdGuard Home)
Search Domain: lan
Status: UP, RUNNING
```

### Production Configuration (ww87)

When deployed at parents' home via `enable-ww87`:

```
Interface: enp2s0f0
IP Address: 192.168.1.100/24 (static)
Gateway: 192.168.1.1 (parents' router)
DNS: 127.0.0.1 (local AdGuard Home)
Search Domain: local
AdGuard Home: Enabled (DNS + DHCP)
```

### Static DHCP Lease

The MAC address `40:6c:8f:18:dd:24` has a static lease configured in miniserver99's AdGuard Home:

```json
{
  "mac": "40:6c:8f:18:dd:24",
  "ip": "192.168.1.100",
  "hostname": "hsb8"
}
```

### Firewall Rules

**Always enabled:**

- TCP: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8883 (MQTT)
- UDP: 443 (HTTPS)

**When at ww87 (parents' home):**

- TCP: 53 (DNS), 3000 (AdGuard Home web UI)
- UDP: 53 (DNS), 67 (DHCP)

**Note:** Wake-on-LAN doesn't require firewall rules - magic packets are received by the NIC hardware when the system is powered off, before the OS/firewall runs.

---

## User Accounts

### SSH Key Security Policy

⚠️ **Important**: This server uses `lib.mkForce` to explicitly override hokage's default SSH keys.

**Security Principle**: Personal/family servers should ONLY have authorized family member keys. The external hokage module (from `github:pbek/nixcfg`) automatically injects external developer keys (omega@yubikey, omega@rsa, etc.) which we explicitly block for security.

**hsb8 Access Policy**:

- ✅ `mba` (Markus) - Personal SSH key
- ✅ `gb` (Gerhard/father) - Personal SSH key
- ❌ NO external developer access
- ❌ NO omega/Yubikey keys

### Primary User: mba

- **UID**: 1000
- **Role**: Primary administrator
- **Home**: `/home/mba`
- **SSH Access**: Explicitly configured with `lib.mkForce` (overrides hokage defaults)
- **SSH Key**: `ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H...` (mba@markus)
- **Sudo**: Passwordless (member of `wheel` group)
- **Groups**: wheel, docker, networkmanager

### Secondary User: gb (Gerhard)

- **Role**: Secondary user for Gerhard (Markus' father)
- **Home**: `/home/gb`
- **SSH Access**: Explicitly configured with `lib.mkForce` (overrides hokage defaults)
- **SSH Key Source**: `Gerhard@imac-gb.local`
- **SSH Key**:
  ```text
  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71qYnLJnq0PPs/PWR0O+0zvEQfT7QYaHbrPUdILnK5jqZTj6o02kyfce6JLk+xyYhI596T6DD9But943cKFY/cYG037EjlECq+LXdS7bRsb8wYdc8vjcyF21Ol6gSJdT3noAzkZnqnucnvd7D1lae2ZVw7km6GQvz5XQGS/LQ38JpPZ2JYb0ufT3Z1vgigq9GqhCU6C7NdUslJJJ1Lj4JfPqQTbS1ihZqMe3SQ+ctfmHNYniUkd5Potu7wLMG1OJDL13BXu/M5IihgerZ3QuPb2VPQkb37oxKfquMKveYL9bt4fmK+7+CRHJnzFB45HfG5PiTKsyjuPR5A1N3U5Os+9Wrav9YrqDHWjCaFI1EIY4HRM/kRufD+0ncvvXpsp4foS9DAhK5g3OObRlKgPEc4hkD7hC2KBXUt7Kyg6SLL89gD42qSXLxZlxaTD65UaqB28PuOt7+LtKEPhm1jfH65cKu5vGqUp3145hSJuHB4FuA0ieplfxO78psVM= Gerhard@imac-gb.local
  ```
- **Configured**: November 16, 2025
- **Tested**: ✅ SSH access confirmed working

---

## Services

### Core System Services

- ✅ **sshd.service** - SSH Daemon (port 22)
- ✅ **docker.service** - Docker Application Container Engine
- ✅ **fail2ban.service** - Intrusion prevention
- ✅ **NetworkManager.service** - Network management
- ✅ **nix-daemon.service** - Nix package manager
- ✅ **systemd-timesyncd.service** - NTP time sync
- ✅ **zfs-zed.service** - ZFS Event Daemon

### AdGuard Home (when at ww87)

**Service**: `adguardhome.service`

**Configuration:**

- **Host**: 0.0.0.0 (all interfaces)
- **DNS Port**: 53
- **Web UI Port**: 3000
- **Upstream DNS**: 1.1.1.1, 1.0.0.1 (Cloudflare)
- **Cache Size**: 4 MB
- **Cache Mode**: Optimistic
- **DHCP**: Disabled by default
  - Range (when enabled): 192.168.1.201 - 192.168.1.254
  - Gateway: 192.168.1.1
  - Lease duration: 24 hours
  - DHCP Option 15: "local" (search domain)

**Based on**: miniserver99's proven AdGuard Home configuration

**Web Interface**: http://192.168.1.100:3000

- Username: `admin`
- Password: `admin` (change after first login!)

### Docker

- **Status**: Running and enabled
- **Network**: Docker bridge at 172.17.0.1/16
- **Purpose**: Ready for home automation containers
- **Current containers**: None (fresh installation)

### Planned Services

For home automation at parents' home:

- Node-RED for automation flows
- MQTT broker (Mosquitto) - port 8883
- HomeKit bridge integration
- Monitoring and logging
- Additional Docker-based services as needed

---

## System Management

### Connecting to the Server

```bash
# Via IP
ssh mba@192.168.1.100

# Via hostname (after DNS resolves)
ssh mba@hsb8.lan

# As Gerhard
ssh gb@192.168.1.100
```

### Wake-on-LAN

**Note:** Wake-on-LAN does not work on Mac mini hardware, even when configured in macOS. The server must remain powered on or be started manually.

### Updating the System

```bash
# Pull latest configuration
cd ~/nixcfg
git pull

# Rebuild system
nixos-rebuild switch --flake .#hsb8

# Or use the just command
just switch
```

### Upgrading NixOS

```bash
cd ~/nixcfg
just upgrade
```

### Checking System Status

```bash
# View system logs
journalctl -f

# Check ZFS health
zpool status
zfs list

# Check Docker containers
docker ps -a

# Check network configuration
ip addr show enp2s0f0
ss -tlnp

# Check AdGuard Home (when at ww87)
systemctl status adguardhome
journalctl -u adguardhome -n 50
```

### Useful Commands

```bash
# Check system generation
nixos-rebuild list-generations

# Rollback to previous generation
nixos-rebuild switch --rollback

# Check firewall rules
sudo nft list ruleset

# Test DNS resolution
dig hsb8.lan
dig -x 192.168.1.100

# Monitor network traffic
sudo tcpdump -i enp2s0f0

# Check DHCP leases (when AdGuard DHCP enabled)
sudo cat /var/lib/private/AdGuardHome/data/leases.json
```

---

## Secret Management with Agenix

hsb8 uses **agenix** for encrypted secret management. This allows sensitive data (like DHCP static leases) to be stored securely in git while still being declaratively managed.

### Overview

- **Tool**: [agenix](https://github.com/ryantm/agenix) - Age-encrypted secrets for NixOS
- **Encryption**: Dual-key (Markus' SSH key + hsb8 host key)
- **Storage**: `secrets/static-leases-hsb8.age` in git repository
- **Runtime**: Decrypts to `/run/agenix/static-leases-hsb8` during system activation

### Secrets Configuration

**File**: `secrets/secrets.nix`

```nix
hsb8 = [
  "ssh-rsa AAAAB3Nz... (hsb8 host key)"
];

"static-leases-hsb8.age".publicKeys = markus ++ hsb8;
```

**What this means:**

1. **Markus' key** - Can edit secrets from Mac or any machine with SSH key
2. **hsb8 host key** - Allows hsb8 to decrypt at runtime
3. **Dual encryption** - Both keys required together for maximum security

### Managed Secrets

| Secret File              | Purpose                    | Format | Count |
| ------------------------ | -------------------------- | ------ | ----- |
| `static-leases-hsb8.age` | DHCP static lease database | JSON   | ~27   |

### Static DHCP Leases

The static leases are based on the Pi-hole backup from parents' network and include:

- **Network Infrastructure**: Orbi routers (3 nodes)
- **Family Devices**: Gerhard's iMac, iPad
- **Smart Home**: 15+ Shelly switches, ESP32 controllers
- **IoT Devices**: Cameras, displays, sensors

**JSON Format:**

```json
[
  {"mac": "78:d2:94:ac:3a:76", "ip": "192.168.1.2", "hostname": "orbi-rbr"},
  {"mac": "98:9e:63:2e:f1:be", "ip": "192.168.1.168", "hostname": "imac-gb"},
  ...
]
```

### Editing Secrets

```bash
# Edit the encrypted static leases file
cd ~/Code/nixcfg
agenix -e secrets/static-leases-hsb8.age

# Your editor opens with decrypted JSON
# Make changes, save, exit → automatically re-encrypted
```

### Validating Secrets

```bash
# Validate JSON format locally
agenix -d secrets/static-leases-hsb8.age | jq empty
# No output = valid JSON

# Count entries
agenix -d secrets/static-leases-hsb8.age | jq 'length'
```

### Deploying Secret Changes

```bash
# After editing and saving the .age file
git add secrets/static-leases-hsb8.age
git commit -m "feat(hsb8): update static DHCP leases"
git push

# On hsb8: Pull and rebuild
cd ~/nixcfg
git pull
just switch
```

### How It Works

```text
1. Edit (Your Mac)
   └─> agenix -e secrets/static-leases-hsb8.age
       └─> Opens editor with decrypted JSON
       └─> Save → re-encrypts → commit to git

2. Deploy (hsb8)
   └─> just switch
       └─> NixOS builds configuration
       └─> System activation
           └─> Agenix decrypts all secrets
               └─> Writes /run/agenix/static-leases-hsb8

3. Service Start (hsb8)
   └─> AdGuard Home starts
       └─> preStart script executes
           ├─> Reads /run/agenix/static-leases-hsb8
           ├─> Validates JSON format
           ├─> Merges with existing dynamic leases
           └─> Writes /var/lib/private/AdGuardHome/data/leases.json
       └─> AdGuard Home starts with complete lease database
```

### Backup Locations

Static leases are backed up in multiple locations:

1. **Git Repository** - `secrets/static-leases-hsb8.age` (encrypted, primary backup)
2. **GitHub** - Pushed to remote repository
3. **Time Machine** on your Mac (includes git repo)
4. **ZFS snapshots** on hsb8 (decrypted file in `/run/agenix/`)

### Troubleshooting

**Secret not decrypted:**

```bash
# Check agenix service
sudo journalctl -u agenix -n 50

# Verify host key matches
cat /etc/ssh/ssh_host_rsa_key.pub
# Should match the key in secrets/secrets.nix

# Check if useSecrets is enabled
grep "useSecrets" ~/nixcfg/hosts/hsb8/configuration.nix
```

**Invalid JSON:**

```bash
# Edit and fix
agenix -e secrets/static-leases-hsb8.age

# Validate before deploying
agenix -d secrets/static-leases-hsb8.age | jq empty
```

**Permission denied:**

1. Verify your SSH key is in `secrets/secrets.nix` (markus key)
2. Verify hsb8 host key is in `secrets/secrets.nix`
3. Check file permissions: `ls -la secrets/static-leases-hsb8.age`

---

## Historical Context

### IP Address Investigation

The IP address `192.168.1.100` was thoroughly investigated before assignment to ensure no conflicts.

**Key Findings:**

- ✅ Not in active use by any machine or service
- ✅ Not assigned in AdGuard Home (current DNS/DHCP server)
- ✅ Only present in inactive Pi-hole configs (legacy, decommissioned)
- ✅ Historically associated with this MAC address (`40:6c:8f:18:dd:24`)

**Historical Usage:**

- Found in old Pi-hole migration backup as "miniserver" at 192.168.1.100
- Same MAC address: `40:6c:8f:18:dd:24`
- Suggests this machine **IS** the old "miniserver" that previously held this IP
- Makes this assignment a **return to its original IP address**

**Investigation Date**: November 16, 2025  
**Result**: Safe to assign 192.168.1.100 to hsb8

### Repository Migration

**Date**: November 16, 2025

**Challenge**: Server was initially configured using a friend's repository (pbek/nixcfg) and needed to be switched to Markus' fork (markus-barta/nixcfg) without breaking anything.

**Original State:**

```
Repository: https://github.com/pbek/nixcfg.git (friend's repo)
Commit: 9116a83 (235 commits behind)
Location: ~/nixcfg
```

**Migration Process:**

1. Renamed 'origin' remote to 'upstream' (kept as backup)
2. Added markus-barta/nixcfg as new 'origin'
3. Fetched and switched to new repository
4. Tested configuration build (dry-run)
5. Deployed successfully via `nixos-rebuild switch`

**Current State:**

```
Repository: https://github.com/markus-barta/nixcfg.git (your fork)
Branch: main
All changes under your control
```

**Safety Features Used:**

- Old repo kept as 'upstream' remote for rollback
- NixOS generations allow instant rollback
- Dry-build validated before deployment
- No downtime during migration

**Result**: ✅ Successfully migrated, all functionality preserved

### SSH Key Configuration

**Date**: November 16, 2025

**Added**: Gerhard's SSH public key for the `gb` user account

**Source**: ~/Downloads/id_rsa.pub from Gerhard's iMac (imac-gb.local)  
**Key Type**: RSA 3072-bit  
**Purpose**: Allow Gerhard remote access to monitor and manage the server

**Testing**: ✅ Confirmed working - Gerhard can connect via:

```bash
ssh gb@192.168.1.100
ssh gb@hsb8.lan
```

### Hostname Migration & External Hokage Consumer

**Date**: November 19-21, 2025

**Migration**: `msww87` → `hsb8` (new unified naming scheme)

**Phase 1 - Hostname Rename** (Nov 19-20, 2025):

1. ✅ Hostname changed from `msww87` to `hsb8`
2. ✅ Folder renamed: `hosts/msww87/` → `hosts/hsb8/`
3. ✅ DHCP static lease updated on miniserver99
4. ✅ DNS resolution working: `hsb8.lan`
5. ✅ All documentation updated
6. ✅ Zero downtime deployment

**Phase 2 - External Hokage Consumer** (Nov 21, 2025):

1. ✅ Added `nixcfg.url = "github:pbek/nixcfg"` input
2. ✅ Removed local `../../modules/hokage` import
3. ✅ Updated flake.nix to use `inputs.nixcfg.nixosModules.hokage`
4. ✅ Test build passed on miniserver24
5. ✅ Deployed successfully
6. ✅ System verification complete

**Result**: hsb8 now uses external hokage module from upstream (github:pbek/nixcfg), following best practices and making it easier to receive hokage updates.

**See**: `MIGRATION-PLAN.md` and `BACKLOG.md` for detailed documentation

### System History

- **Initial Installation**: August 23, 2025
- **Current Uptime Base**: November 16, 2025 (after configuration deployment)
- **Purpose**: Originally tested at Markus' home, to be deployed at parents' home
- **Hardware**: Repurposed Mac mini 2011 (previously the "miniserver")

---

## Troubleshooting

### Network Issues

#### Can't connect via .100 IP

```bash
# Check if IP is configured
ssh mba@192.168.1.100 "ip addr show enp2s0f0"

# Verify static IP is present
# Should show: inet 192.168.1.100/24

# If not, check configuration and rebuild
cd ~/nixcfg
git pull
nixos-rebuild switch --flake .#hsb8
```

#### DNS not resolving hostname

```bash
# Test DNS resolution
dig hsb8.lan

# Check if AdGuard Home is running (at jhw22)
ssh mba@192.168.1.99 "systemctl status adguardhome"

# Check static lease is configured
ssh mba@192.168.1.99 "sudo jq '.leases[] | select(.ip == \"192.168.1.100\")' \
  /var/lib/private/AdGuardHome/data/leases.json"
```

#### Network connectivity lost after rebuild

```bash
# Reboot the machine
sudo reboot

# Or restart NetworkManager
sudo systemctl restart NetworkManager

# Check network status
systemctl status NetworkManager
ip addr show
ip route show
```

### SSH Issues

#### Permission denied (publickey)

```bash
# Verify authorized keys are deployed
cat ~/.ssh/authorized_keys

# Check SSH service status
systemctl status sshd

# Try verbose connection from client
ssh -v mba@192.168.1.100
```

#### Host key verification failed

```bash
# Remove old host key (from client machine)
ssh-keygen -R 192.168.1.100
ssh-keygen -R hsb8.lan

# Try connecting again
ssh mba@192.168.1.100
```

### AdGuard Home Issues (at ww87)

#### Service not starting

```bash
# Check service status
systemctl status adguardhome

# View logs
journalctl -u adguardhome -n 100

# Restart service
sudo systemctl restart adguardhome

# Verify ports are open
ss -tlnp | grep 3000  # Web UI
ss -tlnp | grep 53    # DNS
ss -ulnp | grep 53    # DNS UDP
ss -ulnp | grep 67    # DHCP (if enabled)
```

#### Can't access web interface

```bash
# Verify AdGuard is running
systemctl status adguardhome

# Check if port 3000 is listening
ss -tlnp | grep 3000

# Test from server itself
curl http://localhost:3000

# Check firewall
sudo nft list ruleset | grep 3000
```

#### DHCP not working (if enabled)

```bash
# Verify DHCP is enabled in config
grep -A 5 "dhcp = {" ~/nixcfg/hosts/hsb8/configuration.nix

# Check if DHCP port is open
ss -ulnp | grep 67

# View DHCP leases
sudo cat /var/lib/private/AdGuardHome/data/leases.json

# Check AdGuard logs for DHCP activity
journalctl -u adguardhome | grep -i dhcp
```

### System Issues

#### System won't boot after update

Boot from the previous generation:

1. At boot menu (GRUB), select previous generation
2. Once booted, rollback:
   ```bash
   sudo nixos-rebuild switch --rollback
   ```

#### Out of disk space

```bash
# Check disk usage
df -h
zfs list -o space

# Clean old generations
sudo nix-collect-garbage -d

# Clean old Docker images
docker system prune -a
```

#### ZFS pool issues

```bash
# Check pool status
zpool status

# Check for errors
zpool status -x

# Scrub the pool
sudo zpool scrub zroot

# Check scrub progress
zpool status zroot
```

### Configuration Issues

#### Build fails after git pull

```bash
# Update flake inputs
nix flake update

# Try building again
nixos-rebuild build --flake .#hsb8

# If still failing, check for syntax errors
nix flake check
```

#### enable-ww87 script not found

```bash
# Rebuild system to add script
cd ~/nixcfg
nixos-rebuild switch --flake .#hsb8

# Verify script is available
which enable-ww87
```

### Getting Help

If you encounter issues not covered here:

1. **Check system logs**: `journalctl -xe`
2. **Check service status**: `systemctl status <service>`
3. **Test configuration build**: `nixos-rebuild dry-build --flake .#hsb8`
4. **Review recent changes**: `git log -10 --oneline`
5. **Rollback if needed**: `nixos-rebuild switch --rollback`

---

## Related Documentation

### In This Repository

- [Main README](../../README.md) - Repository overview and quick start
- [How It Works](../../docs/how-it-works.md) - Architecture and machine inventory
- [Overview](../../docs/overview.md) - Technical reference and workflows
- [Hokage Module Options](../../docs/hokage-options.md) - Configuration options reference

### Similar Setups

- [miniserver99](../miniserver99/README.md) - DNS/DHCP server with AdGuard Home
- [miniserver24](../miniserver24/configuration.nix) - Home automation hub reference

### Configuration Files

- [configuration.nix](./configuration.nix) - Main system configuration
- [hardware-configuration.nix](./hardware-configuration.nix) - Hardware-specific settings
- [disk-config.zfs.nix](./disk-config.zfs.nix) - ZFS disk layout

---

## Changelog

### 2025-11-22: Agenix Secret Management Added

- ✅ **Agenix Integration** (F19): Encrypted secret management for DHCP static leases
  - Created `secrets/static-leases-hsb8.age` with 27 static DHCP leases
  - Dual-key encryption (Markus SSH key + hsb8 host key)
  - Based on Pi-hole backup data from parents' network
- ✅ **Documentation**: Comprehensive "Secret Management with Agenix" section added
  - JSON format, editing workflow, deployment process
  - Backup locations, troubleshooting guide
- ✅ **Test Suite** (T19): Manual and automated tests for secret management
  - Tests agenix CLI, rage encryption tool, secret configuration
  - Validates JSON format and host key setup

**Impact**: Static leases ready for deployment. When DHCP is enabled at ww87, all 27 devices (Orbi routers, Shelly switches, family devices, IoT) will automatically receive their static IP assignments.

### 2025-11-22: Missing Configuration Features Added

- ✅ **User Identity**: Added `userNameLong`, `userNameShort`, `userEmail` to hokage config
  - Prevents git commits from being attributed to "Patrizio Bekerle"
  - Ensures correct authorship: "Markus Barta <markus@barta.com>"
- ✅ **Fish Shell Utilities**: Added `programs.fish.interactiveShellInit` block
  - Restored `sourcefish` function for loading .env files
  - Set `EDITOR=nano` for consistent editing experience
- ✅ **Local /etc/hosts**: Added `networking.hosts` configuration
  - Privacy-focused hostnames (cryptic/encoded device names)
  - Fallback DNS resolution when AdGuard Home unavailable
  - Self-resolution for hsb8 and hsb8.lan
- ✅ **Test Suite**: Created T16-T18 tests with manual and automated procedures
- 📋 **Reason**: These features were provided by `serverMba.enable` mixin in local hokage
- 🎯 **Impact**: Brings hsb8 to feature parity with hsb0 and other servers

**Features Added**:

- F16: User Identity Config (git authorship)
- F17: Fish Shell Utilities (sourcefish, EDITOR)
- F18: Local /etc/hosts (privacy-focused hostnames)

### 2025-11-22: SSH Key Security Fix (CRITICAL)

- 🚨 **Issue**: Server lockout after reboot - mba user couldn't SSH in
- 🔍 **Root Cause**: Hokage `server-home.nix` auto-injects external keys (omega@\*), mba key was missing
- ✅ **Fix**: Added `lib.mkForce` to explicitly override hokage's SSH keys
- ✅ **Security**: Only family keys allowed (mba + gb), NO external access
- ⚠️ **Status**: Fix committed, requires physical access to deploy

**Configuration**:

```nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # mba@markus ONLY
  ];
};
```

**Lesson**: External hokage modules may inject unwanted config. Always audit and override security-critical settings with `lib.mkForce`.

### 2025-11-22: Hokage Configuration Correction

- ✅ Fixed hokage configuration to use proper external consumer pattern
- ✅ Removed: `serverMba.enable = true` (local mixin)
- ✅ Added: Explicit options (role, userLogin, useInternalInfrastructure, etc.)
- ✅ Now compliant with official hokage-consumer examples
- ✅ Deployed successfully with zero downtime

**Reason**: Original Nov 21 migration used external hokage in flake.nix but still relied on local mixin in configuration.nix

**Result**: hsb8 now properly uses external hokage module with explicit configuration

### 2025-11-21: External Hokage Consumer Migration

- ✅ Added `nixcfg.url = "github:pbek/nixcfg"` flake input
- ✅ Removed local `../../modules/hokage` import from configuration
- ✅ Updated flake.nix to use `inputs.nixcfg.nixosModules.hokage`
- ✅ Test build validated on miniserver24 (16GB RAM, native NixOS)
- ✅ Deployed successfully with zero downtime
- ✅ All services running normally
- ✅ System verification complete

**Result**: Now using external hokage module from upstream (github:pbek/nixcfg)

### 2025-11-19: Hostname Migration (msww87 → hsb8)

- ✅ Adopted new unified naming scheme: `hsb8` (Home Server Barta 8)
- ✅ Renamed folder: `hosts/msww87/` → `hosts/hsb8/`
- ✅ Updated hostname in configuration.nix
- ✅ Updated DHCP static lease on miniserver99
- ✅ Updated all documentation and references
- ✅ DNS resolution working: `hsb8.lan`
- ✅ Zero downtime deployment

**Result**: Successfully renamed with improved naming consistency

### 2025-11-16: Initial Setup and Configuration

- ✅ Discovered machine running at 192.168.1.223 (DHCP)
- ✅ Investigated and approved 192.168.1.100 IP address assignment
- ✅ Identified MAC address matches historical "miniserver" (same hardware)
- ✅ Added Gerhard's SSH public key for `gb` user
- ✅ Successfully migrated from pbek/nixcfg to markus-barta/nixcfg repository
- ✅ Configured static IP 192.168.1.100
- ✅ Added static DHCP lease to miniserver99
- ✅ Implemented location-based configuration (jhw22/ww87)
- ✅ Added enable-ww87 one-command deployment script
- ✅ Configured AdGuard Home for ww87 location
- ✅ Deployed and tested all configurations
- ✅ Verified SSH access for both users
- ✅ Confirmed network connectivity at jhw22

**Result**: Fully configured and ready for deployment

---

**Current Status**: Ready for deployment to parents' home (ww87)

**Next Step**: Run `enable-ww87` when machine is physically moved to parents' home

---

**Last Updated**: November 21, 2025  
**Maintainer**: Markus Barta  
**Repository**: https://github.com/markus-barta/nixcfg
