# miniserver99 - DNS/DHCP Server

## Purpose

Primary DNS and DHCP server running **AdGuard Home** as a native NixOS service, replacing the Pi-hole setup from miniserver24.

## Quick Reference

- **IP Address**: `192.168.1.99/24`
- **Gateway**: `192.168.1.5` (Fritz!Box)
- **DNS**: Uses localhost (127.0.0.1) - AdGuard Home
- **DHCP Range**: `192.168.1.201` - `192.168.1.254`
- **Web Interface**: [http://192.168.1.99:3000](http://192.168.1.99:3000)
- **SSH**: `ssh mba@192.168.1.99`

## System Details

- **Hardware**: Mac mini (Intel)
- **ZFS hostId**: `dabfdb02`
- **User**: `mba` (Markus Barta)
- **Role**: `server-home` (via `serverMba.enable`)
- **Network Interface**: `enp2s0f0`

## Firewall Ports

- **TCP 53**: DNS queries
- **UDP 53**: DNS queries
- **UDP 67**: DHCP server
- **TCP 3000**: AdGuard Home web interface
- **TCP 22**: SSH
- **TCP 80/443**: Reserved for future use

---

## Installation

### Prerequisites

- ✅ **Boot Media**: USB stick with NixOS minimal ISO (nixos-minimal-25.05 or later)
- ✅ **Source Machine**: miniserver24 (192.168.1.101) or your Mac
- ✅ **Network**: All machines on same network (192.168.1.x)
- ✅ **Static Lease Data**: Encrypted in `secrets/static-leases-miniserver99.age` (managed by agenix)

### Step 1: Boot from USB

1. Insert USB stick into Mac mini
2. Power on while holding **⌥ Option (Alt)** key
3. Select USB stick from boot menu
4. Wait for NixOS minimal environment to boot

### Step 2: Configure Minimal Environment

```bash
# Set root password (needed for SSH)
sudo passwd

# Check network interface
ip link show
# Expected: enp2s0f0

# Get IP address assigned by DHCP
ip addr show
# Note this IP for nixos-anywhere

# Verify connectivity
ping 1.1.1.1
```

### Step 3: Deploy with nixos-anywhere

**From miniserver24 (RECOMMENDED):**

```bash
# SSH into miniserver24
ssh mba@192.168.1.101

# Navigate to repository
cd ~/Code/nixcfg

# Deploy (replace 192.168.1.150 with actual IP from step 2)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@192.168.1.150
```

**From your Mac:**

```bash
cd ~/Code/nixcfg

# Deploy
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@192.168.1.150
```

### Step 4: First Boot

1. Remove USB stick
2. Machine reboots into NixOS at `192.168.1.99`
3. Wait ~30 seconds for boot

### Step 5: Verify Installation

```bash
# SSH into new system
ssh mba@192.168.1.99

# Check AdGuard Home status
systemctl status adguardhome
journalctl -u adguardhome -f

# Check ZFS pool
zpool status

# Verify network configuration
ip addr show enp2s0f0

# Test DNS
dig @localhost google.com

# Access web interface
# [http://192.168.1.99:3000](http://192.168.1.99:3000)
```

---

## Configuration Management

### Deploying Changes

```bash
# On miniserver99
cd ~/Code/nixcfg
git pull
just switch
```

### Useful Justfile Commands

```bash
# Switch configuration
just switch

# Edit static leases (using agenix)
just edit-secret secrets/static-leases-miniserver99.age

# Update flake inputs and rebuild
just upgrade

# Clean up old generations
just cleanup

# View all available commands
just --list
```

**Documentation:**

- [Repository README](../../docs/README.md) - Complete NixOS configuration guide and justfile commands

### Modifying AdGuard Home Settings

All settings are declarative in `configuration.nix`. Examples:

```nix
# Change DHCP range
services.adguardhome.settings.dhcp = {
  range_start = "192.168.1.201";
  range_end = "192.168.1.254";
  lease_duration = 86400; # 24 hours
};

# Change upstream DNS
services.adguardhome.settings.dns = {
  bootstrap_dns = [ "9.9.9.9" "149.112.112.112" ]; # Quad9
  upstream_dns = [ "9.9.9.9" "149.112.112.112" ];
};

# Adjust DNS cache
services.adguardhome.settings.dns = {
  cache_size = 8388608; # 8MB
  cache_optimistic = true;
};
```

Apply changes:

```bash
# Standard rebuild
just switch
```

---

## Static DHCP Leases

### Overview

All 107 static DHCP leases are managed using **agenix** (encrypted secrets). The encrypted file `secrets/static-leases-miniserver99.age` contains a **JSON array** that is:

- ✅ **Single Source of Truth**: The `.age` file in git is the canonical source
- ✅ **Encrypted**: Uses dual-key encryption (your SSH key + miniserver99 host key)
- ✅ **Automatic Decryption**: Agenix decrypts to `/run/agenix/static-leases-miniserver99` at system activation
- ✅ **Runtime Loading**: preStart script reads JSON and merges into AdGuard's leases database
- ✅ **Build-time Independent**: No import at Nix evaluation time - works correctly!

### How It Works - Complete Flow

```
1. Edit (Your Mac)
   └─> agenix -e secrets/static-leases-miniserver99.age
       └─> Opens editor with JSON
       └─> Save → re-encrypts → commit to git

2. Deploy (miniserver99)
   └─> just switch
       └─> NixOS builds configuration (no static leases needed yet!)
       └─> System activation
           └─> Agenix decrypts all secrets
               └─> Writes /run/agenix/static-leases-miniserver99

      3. Service Start (miniserver99)
         └─> AdGuard Home starts
             └─> preStart script executes
                 ├─> Reads /run/agenix/static-leases-miniserver99
                 ├─> Validates JSON format
                 ├─> Merges with existing dynamic leases
                 └─> Writes /var/lib/private/AdGuardHome/data/leases.json
             └─> AdGuard Home starts with complete lease database
```

### JSON Format

The `.age` file contains a simple JSON array:

```json
[
  {
    "mac": "AA:BB:CC:DD:EE:FF",
    "ip": "192.168.1.100",
    "hostname": "device-name"
  },
  {
    "mac": "11:22:33:44:55:66",
    "ip": "192.168.1.101",
    "hostname": "another-device"
  }
]
```

**Field Requirements:**

- `mac`: MAC address (any case, normalized to lowercase automatically)
- `ip`: IPv4 address
- `hostname`: Device hostname
- Optional: `client_id` for devices using DHCP client IDs

### Managing Static Leases

**Edit leases:**

```bash
# Edit the encrypted JSON file
agenix -e secrets/static-leases-miniserver99.age

# Your editor opens with the decrypted JSON
# Make changes, save, exit → automatically re-encrypted
```

**Validate JSON locally:**

```bash
# Before deploying, you can validate
agenix -d secrets/static-leases-miniserver99.age | jq empty
# No output = valid JSON
```

**Deploy changes:**

```bash
# Rebuild system
just switch

# The preStart script will:
# 1. Read the agenix-decrypted JSON
# 2. Validate format
# 3. Merge with dynamic leases
# 4. Report: "✓ Loaded X static DHCP leases"
```

**Check deployed leases:**

```bash
# On miniserver99
sudo jq '.leases[] | select(.static == true)' \
  /var/lib/private/AdGuardHome/data/leases.json
```

### Security Model - Dual-Key Encryption

**Implementation Date:** November 15, 2025

Static leases are encrypted with **two keys** in `secrets/secrets.nix`:

```nix
"static-leases-miniserver99.age".publicKeys = markus ++ miniserver99;
```

**What this means:**

1. **Your personal key** (`markus`) - Edit from Mac or any machine with your SSH key
2. **miniserver99 host key** - System can decrypt at activation (no manual intervention)

**Key locations:**

- Personal key: `~/.ssh/id_rsa` (or `id_ed25519`, `id_ecdsa`)
- Host key: `/etc/ssh/ssh_host_ed25519_key` (on miniserver99)

**Benefits:**

- ✅ Edit secrets from your Mac without being on the server
- ✅ Server can decrypt automatically during `nixos-rebuild`
- ✅ No plaintext files ever stored in git
- ✅ Lost personal key? Server can still decrypt with its host key

### Backup Locations

The static leases are backed up in multiple locations:

1. **Git Repository** - `secrets/static-leases-miniserver99.age` (encrypted, primary backup)
2. **GitHub** - Pushed to remote repository
3. **Time Machine** on your Mac (includes git repo)
4. **ZFS snapshots** on miniserver99 (decrypted file in `/run/agenix/`)
5. **Optional**: 1Password (store a backup copy of the `.age` file)

### Error Handling & Troubleshooting

**Service fails to start:**

```bash
# Check the preStart script output
sudo journalctl -u adguardhome -n 50

# Common errors:
# "ERROR: Static leases file not found" → agenix didn't decrypt (check age.secrets config)
# "ERROR: Invalid JSON" → Fix with: agenix -e secrets/static-leases-miniserver99.age
```

**Validate before deploying:**

```bash
# Test JSON format locally
agenix -d secrets/static-leases-miniserver99.age | jq empty

# Count entries
agenix -d secrets/static-leases-miniserver99.age | jq 'length'
```

**Rollback if needed:**

```bash
# Revert to previous configuration
sudo nixos-rebuild switch --rollback

# Or restore from git history
git log secrets/static-leases-miniserver99.age
git show COMMIT:secrets/static-leases-miniserver99.age > /tmp/restored.age
```

### Migration from Nix to JSON Format

**If you have an existing Nix-format `.age` file, convert it:**

```bash
# 1. Read the current Nix file
cat hosts/miniserver99/static-leases.nix

# 2. Convert to JSON using nix-instantiate
nix-instantiate --eval --strict --json -E '
  let data = import ./hosts/miniserver99/static-leases.nix;
  in data.static_leases
' | jq '.' > /tmp/static-leases.json

# 3. Encrypt the JSON with agenix
agenix -e secrets/static-leases-miniserver99.age
# (paste the JSON content, save, exit)

# 4. Verify
agenix -d secrets/static-leases-miniserver99.age | jq empty

# 5. Deploy
git add secrets/static-leases-miniserver99.age
git commit -m "chore: migrate static leases to JSON format"
just switch
```

---

## SSH Keys

### Your SSH Keys

**Personal (Use for NixOS):**

- `~/.ssh/id_rsa` + `.pub`
- RSA, created June 2019
- ✅ Configured in `secrets/secrets.nix` for private-only access

**Company (BYTEPOETS):**

- `~/.ssh/id_ed25519_bytepoets` + `.pub`
- ED25519, for work only

**Backup:** Store private key `~/.ssh/id_rsa` in 1Password as secure note

### SSH Host Keys (miniserver99)

Automatically generated by NixOS during installation:

- `/etc/ssh/ssh_host_rsa_key` (private)
- `/etc/ssh/ssh_host_rsa_key.pub` (public)

Public key extracted for agenix:

```bash
ssh-keyscan 192.168.1.99
```

---

## AdGuard Home Features

### DNS Management

- Ad-blocking and tracker blocking
- Custom DNS filtering rules
- DNS-over-HTTPS (DoH) and DNS-over-TLS (DoT) support
- Configurable upstream DNS servers (currently Cloudflare: 1.1.1.1, 1.0.0.1)
- DNS query logging and statistics
- Custom DNS rewrites

### DHCP Management

- DHCP server with range 192.168.1.201-254
- 107 static DHCP lease assignments (declarative, encrypted with agenix)
- Custom DHCP options
- Integration with DNS resolution

### Administration

- Web interface: [http://192.168.1.99:3000](http://192.168.1.99:3000)
- Username: `admin`
- Password: Set declaratively in configuration
- Query log with search and filtering
- Real-time statistics dashboard

---

## Enabled Services

### Core Services

- **AdGuard Home**: DNS/DHCP with ad-blocking
- **SSH**: Key-based authentication
- **Docker**: Container runtime (if needed)
- **ZFS**: Automatic scrubbing and snapshots
- **Fail2ban**: Intrusion prevention (ignores 192.168.1.0/16)
- **Firewall**: iptables/nftables packet filtering

---

## Useful Commands

### Service Management

```bash
# AdGuard Home
systemctl status adguardhome
journalctl -u adguardhome -f
sudo systemctl restart adguardhome

# Check config
sudo cat /var/lib/AdGuardHome/AdGuardHome.yaml
```

### Network Diagnostics

```bash
# Check ZFS pool
zpool status

# Monitor network traffic
sudo tcpdump -i enp2s0f0 port 53

# Check DNS resolution
dig @localhost example.com
dig @192.168.1.99 example.com

# Check DHCP leases
cat /var/lib/private/AdGuardHome/data/leases.json
```

### System Maintenance

```bash
# View system logs
journalctl -f
journalctl -b -e  # Current boot
journalctl -b-1   # Previous boot

# Check firewall
sudo nft list ruleset

# Check gateway route
ip route show
```

---

## Migration from miniserver24 (Pi-hole)

### What Actually Happened (Successful Cutover)

The migration was straightforward with minimal downtime:

1. **Preparation:**
   - Deployed miniserver99 at 192.168.1.99
   - Configured AdGuard Home with all static leases
   - Added equivalent blocklists from Pi-hole
   - Verified configuration

2. **Cutover (Evening, Low Traffic):**
   - Stopped Pi-hole container on miniserver24
   - miniserver99 took over DNS/DHCP immediately
   - **Minimal downtime**: ~2-3 minutes while services switched
   - No manual DHCP renewal needed (24-hour lease time meant clients renewed automatically)

3. **Post-Cutover:**
   - Monitored AdGuard Home query logs for first 24 hours
   - No client issues encountered
   - All devices received correct IPs via static leases

### Why Parallel Testing Wasn't Feasible

Both Pi-hole (miniserver24) and AdGuard Home (miniserver99) were configured for **192.168.1.99**, so running them simultaneously would cause IP conflicts. The solution was a quick cutover instead.

### Rollback Plan (If Needed)

**Quick Rollback:**

```bash
# Stop AdGuard Home on miniserver99
ssh mba@192.168.1.99
sudo systemctl stop adguardhome

# Restart Pi-hole container on miniserver24
ssh mba@192.168.1.101
sudo docker start pihole
```

With 24-hour DHCP leases, clients automatically pick up the restored service without manual intervention.

---

## Current Deployment Status

**Date:** November 12, 2025  
**Status:** ✅ Deployed and Running

### Completed

- ✅ Initial deployment via nixos-anywhere
- ✅ Network configuration (interface: enp2s0f0, gateway: 192.168.1.5)
- ✅ AdGuard Home configured and running
- ✅ DHCP enabled with 107 static leases (encrypted with agenix)
- ✅ DNS rewrites for internal hosts
- ✅ Repository cloned to ~/Code/nixcfg on miniserver99
- ✅ Admin credentials configured

### Notes

- All configuration is declarative (`mutableSettings = false`)
- Static leases are encrypted in git using agenix (dual-key: personal + host key)
- Gateway IP 192.168.1.5 verified from actual network
- Network interface enp2s0f0 verified from hardware

---

## Architecture

### Design Principles

- **Minimal attack surface**: Headless server, no GUI
- **Declarative configuration**: All settings in version control
- **Automatic backup**: ZFS snapshots + encrypted Git backups
- **Low resource utilization**: Optimized for Mac mini
- **High availability**: Quick rollback with NixOS generations

### Included

- AdGuard Home (DNS/DHCP)
- SSH remote access
- ZFS with automatic snapshots
- Firewall with restricted ports
- Fail2ban intrusion prevention
- Firmware updates (fwupd)

### Excluded

- No graphical environment
- No audio subsystem
- No desktop applications
- No IoT/home automation
- No media services

---

## Additional Resources

- **AdGuard Home Documentation**: [https://github.com/AdguardTeam/AdGuardHome/wiki](https://github.com/AdguardTeam/AdGuardHome/wiki)
- **NixOS Manual**: [https://nixos.org/manual/nixos/stable/](https://nixos.org/manual/nixos/stable/)
- **Disko (ZFS setup)**: [https://github.com/nix-community/disko](https://github.com/nix-community/disko)
- **nixos-anywhere**: [https://github.com/nix-community/nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
- **agenix (secrets)**: [https://github.com/ryantm/agenix](https://github.com/ryantm/agenix)
