# msww87 - Parents' Home Automation Server

**Mac mini 2011** (Intel i5-2415M) running NixOS for home automation at parents' home.

---

## Quick Reference

| Item                  | Value                                                                      |
| --------------------- | -------------------------------------------------------------------------- |
| **Hostname**          | `msww87`                                                                   |
| **Model**             | Mac mini 2011 (Intel i5-2415M @ 2.30GHz)                                   |
| **RAM**               | 8 GB                                                                       |
| **Storage**           | 112 GB SSD with ZFS                                                        |
| **Static IP**         | `192.168.1.100`                                                            |
| **MAC Address**       | `40:6c:8f:18:dd:24`                                                        |
| **Network Interface** | `enp2s0f0`                                                                 |
| **SSH Access**        | `ssh mba@192.168.1.100` or `ssh mba@msww87.lan`                            |
| **Location**          | Currently at jhw22 (Markus' home), deployment target: ww87 (parents' home) |
| **Users**             | `mba` (admin), `gb` (Gerhard)                                              |
| **ZFS Host ID**       | `cdbc4e20`                                                                 |

---

## Current Status

✅ **Deployed and Running** (November 16, 2025)

- **Location**: `jhw22` (testing at Markus' home)
- **Static IP**: `192.168.1.100` configured
- **Repository**: Successfully switched from pbek/nixcfg to markus-barta/nixcfg
- **SSH Keys**: Gerhard's public key configured for `gb` user
- **AdGuard Home**: Ready to activate at parents' home (currently disabled)
- **DHCP Server**: Disabled by default for safety

**Ready for deployment**: Run `enable-ww87` when machine is moved to parents' home.

---

## Table of Contents

1. [Location-Based Configuration](#location-based-configuration)
2. [One-Command Deployment (enable-ww87)](#one-command-deployment-enable-ww87)
3. [Hardware Specifications](#hardware-specifications)
4. [Network Configuration](#network-configuration)
5. [User Accounts](#user-accounts)
6. [Services](#services)
7. [System Management](#system-management)
8. [Historical Context](#historical-context)
9. [Troubleshooting](#troubleshooting)

---

## Location-Based Configuration

The msww87 server uses a **location-based configuration** that adapts network settings and services based on physical location.

### Available Locations

| Location | Name          | Gateway     | DNS               | Search Domain | AdGuard Home |
| -------- | ------------- | ----------- | ----------------- | ------------- | ------------ |
| `jhw22`  | Markus' home  | 192.168.1.5 | 192.168.1.99      | lan           | Disabled     |
| `ww87`   | Parents' home | 192.168.1.1 | 127.0.0.1 (local) | local         | Enabled      |

### How It Works

The location is set in `hosts/msww87/configuration.nix`:

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

### Usage

```bash
# SSH into the server
ssh mba@192.168.1.100

# Run the deployment script
enable-ww87
```

The script will:

1. ✅ Change location from "jhw22" → "ww87"
2. ✅ Commit and push changes to Git
3. ✅ Apply configuration via `nixos-rebuild switch`
4. ✅ Enable AdGuard Home (DNS + web UI)
5. ✅ Update network settings automatically
6. ✅ Show status and next steps

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
nano ~/nixcfg/hosts/msww87/configuration.nix

# Find line (around line 113):
#   enabled = false;  # TODO: Enable when ready

# Change to:
#   enabled = true;

# Commit and deploy
cd ~/nixcfg
git add hosts/msww87/configuration.nix
git commit -m "feat(msww87): enable DHCP server"
git push
nixos-rebuild switch --flake .#msww87

# Verify
systemctl status adguardhome
ss -ulnp | grep :67
```

### Reverting to jhw22

To switch back to Markus' home configuration:

```bash
cd ~/nixcfg
nano hosts/msww87/configuration.nix
# Change: location = "ww87" → location = "jhw22"
git add hosts/msww87/configuration.nix
git commit -m "feat(msww87): revert to jhw22 location"
git push
nixos-rebuild switch --flake .#msww87
```

---

## Hardware Specifications

### System Details

- **Model**: Mac mini 2011 (Intel-based)
- **CPU**: Intel Core i5-2415M @ 2.30GHz
  - 2 cores, 4 threads
  - Sandy Bridge architecture
- **RAM**: 7.7 GB usable (8 GB installed)
- **Storage**: 111.8 GB SSD
- **Network**: Gigabit Ethernet (enp2s0f0)
- **Wireless**: Broadcom adapter (driver available, currently unused)

### Software

- **OS**: NixOS 25.11 (Xantusia)
- **Kernel**: Linux 6.15.10
- **Architecture**: x86_64 GNU/Linux
- **ZFS Host ID**: `cdbc4e20`
- **Machine ID**: `94f5aa5a70c24ddf99c7903586a66606`

### Disk Layout

```
NAME     SIZE   TYPE  MOUNTPOINT
sda      111.8G disk
├─sda1   1M     part  (BIOS boot)
├─sda2   500M   part  /boot
└─sda3   111.3G part  (ZFS)
zram0    3.8G   disk  [SWAP]
```

### ZFS Configuration

```
Pool: zroot
State: ONLINE (healthy)
Disk: disk-disk1-zfs

Filesystems:
- zroot/root  → /     (896 KB used)
- zroot/nix   → /nix  (2.5 GB used)
- zroot/home  → /home (4.0 MB used)
- zroot       → /zroot (128 KB used)

Available: 106 GB free
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
  "hostname": "msww87"
}
```

### Firewall Rules

**Always enabled:**

- TCP: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8883 (MQTT)
- UDP: 443 (HTTPS)

**When at ww87 (parents' home):**

- TCP: 53 (DNS), 3000 (AdGuard Home web UI)
- UDP: 53 (DNS), 67 (DHCP)

---

## User Accounts

### Primary User: mba

- **UID**: 1000
- **Role**: Primary administrator
- **Home**: `/home/mba`
- **SSH Access**: Configured with public key
- **Sudo**: Passwordless (member of `wheel` group)
- **Groups**: wheel, docker, networkmanager

### Secondary User: gb (Gerhard)

- **Role**: Secondary user for Gerhard (Markus' father)
- **Home**: `/home/gb`
- **SSH Access**: Configured with public key
- **SSH Key Source**: `Gerhard@imac-gb.local`
- **SSH Key**:
  ```
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
ssh mba@msww87.lan

# As Gerhard
ssh gb@192.168.1.100
```

### Updating the System

```bash
# Pull latest configuration
cd ~/nixcfg
git pull

# Rebuild system
nixos-rebuild switch --flake .#msww87

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
dig msww87.lan
dig -x 192.168.1.100

# Monitor network traffic
sudo tcpdump -i enp2s0f0

# Check DHCP leases (when AdGuard DHCP enabled)
sudo cat /var/lib/private/AdGuardHome/data/leases.json
```

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
**Result**: Safe to assign 192.168.1.100 to msww87

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
ssh gb@msww87.lan
```

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
nixos-rebuild switch --flake .#msww87
```

#### DNS not resolving hostname

```bash
# Test DNS resolution
dig msww87.lan

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
ssh-keygen -R msww87.lan

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
grep -A 5 "dhcp = {" ~/nixcfg/hosts/msww87/configuration.nix

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
nixos-rebuild build --flake .#msww87

# If still failing, check for syntax errors
nix flake check
```

#### enable-ww87 script not found

```bash
# Rebuild system to add script
cd ~/nixcfg
nixos-rebuild switch --flake .#msww87

# Verify script is available
which enable-ww87
```

### Getting Help

If you encounter issues not covered here:

1. **Check system logs**: `journalctl -xe`
2. **Check service status**: `systemctl status <service>`
3. **Test configuration build**: `nixos-rebuild dry-build --flake .#msww87`
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

**Current Status**: Ready for deployment to parents' home (ww87)

**Next Step**: Run `enable-ww87` when machine is physically moved to parents' home

---

**Last Updated**: November 16, 2025  
**Maintainer**: Markus Barta  
**Repository**: https://github.com/markus-barta/nixcfg
