# miniserver99 - DNS/DHCP Server

## Purpose

Primary DNS and DHCP server running **AdGuard Home** as a native NixOS service, replacing the Pi-hole setup from miniserver24.

## Quick Reference

- **IP Address**: `192.168.1.99/24`
- **Gateway**: `192.168.1.5` (Fritz!Box)
- **DNS**: Uses localhost (127.0.0.1) - AdGuard Home
- **DHCP Range**: `192.168.1.201` - `192.168.1.254`
- **Web Interface**: http://192.168.1.99:3000
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
- ✅ **Static Lease Data**: `hosts/miniserver99/static-leases.nix` available locally

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

# Ensure static-leases.nix exists
ls -la hosts/miniserver99/static-leases.nix

# Deploy (replace 192.168.1.150 with actual IP from step 2)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  --override-input miniserver99-static-leases \
  path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix \
  root@192.168.1.150
```

**From your Mac:**

```bash
cd ~/Code/nixcfg

# Deploy
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  --override-input miniserver99-static-leases \
  path:/Users/markus/Code/nixcfg/hosts/miniserver99/static-leases.nix \
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
# http://192.168.1.99:3000
```

---

## Configuration Management

### Deploying Changes

```bash
# On miniserver99
cd ~/Code/nixcfg
git pull

# Use justfile command (recommended)
just switch

# Or use native nixos-rebuild (with static leases override)
sudo nixos-rebuild switch \
  --flake .#miniserver99 \
  --override-input miniserver99-static-leases \
  path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix
```

### Useful Justfile Commands

```bash
# Encrypt static leases for backup
just encrypt-file hosts/miniserver99/static-leases.nix

# Decrypt static leases from backup
just decrypt-file secrets/static-leases-miniserver99.age

# Switch configuration
just switch

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
# Recommended
just switch

# Alternative: native command
sudo nixos-rebuild switch --flake .#miniserver99
```

---

## Static DHCP Leases

### Overview

All 115+ static DHCP leases are configured declaratively in `static-leases.nix`. The file is:
- ✅ **Gitignored**: Contains MAC addresses and network topology
- ✅ **Encrypted**: Backed up in Git as `secrets/static-leases-miniserver99.age`
- ✅ **Declarative**: Synced automatically during deployment

### File Structure

```nix
{
  static_leases = [
    { mac = "AA:BB:CC:DD:EE:FF"; ip = "192.168.1.100"; hostname = "device-name"; }
    # ... more leases
  ];
}
```

### Managing Static Leases

**Edit leases:**

```bash
nano hosts/miniserver99/static-leases.nix
```

**Deploy changes:**

```bash
# Recommended
just switch

# Alternative: native command with override
sudo nixos-rebuild switch \
  --flake .#miniserver99 \
  --override-input miniserver99-static-leases \
  path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix
```

**Backup to Git (encrypted):**

```bash
# Encrypt and stage
just encrypt-file hosts/miniserver99/static-leases.nix

# Commit
git commit -m "backup: update static leases"
git push
```

**What happens during encryption:**
- Uses **both your SSH key and miniserver99's host key**
- Either you (on your Mac) or miniserver99 can decrypt
- **Security checks**: Warns if SSH key has no passphrase or file exists in Git history
- **Validation**: Tests that encrypted file can be decrypted
- Automatically adds plaintext to `.gitignore` (atomic update)
- Stages encrypted file for commit

**Restore from Git:**

```bash
# After cloning repo on new machine
just decrypt-file secrets/static-leases-miniserver99.age
```

### Security Model - Dual-Key Encryption (Option C)

**Implementation Date:** November 12, 2025

The encryption system uses a dual-key approach following the same pattern as the friend's `general` keys setup:

- **Encryption Keys**: Uses BOTH your Mac's SSH public key (from `secrets.nix`) AND miniserver99's host public key
- **Decryption**: Either key can independently decrypt the file
- **Cross-Machine**: Encrypt from Mac OR miniserver99, decrypt on either machine
- **User Key Storage**: Your public key is stored in `secrets.nix` under `markus = [...]`
- **Fallback Logic**: Uses local SSH key if available, otherwise reads from `secrets.nix`

**End-to-End Validation (Completed):**

✅ **Test 1 (Server → Mac):**
- Modified file on miniserver99 (`test-entry`)
- Encrypted on miniserver99 using key from `secrets.nix`
- Decrypted on Mac using local user key
- File integrity: 100% preserved

✅ **Test 2 (Mac → Server):**
- Modified file on Mac (`test-entry-validated`)
- Encrypted on Mac using local user key
- Decrypted on miniserver99 using host key
- File integrity: 100% preserved

**Security Features:**
- ✅ Passphrase check (warns if SSH key unprotected)
- ✅ Git history check (warns if plaintext was committed)
- ✅ Encryption validation (tests decryption immediately)
- ✅ Atomic .gitignore updates (no race conditions)
- ✅ Automatic backups (timestamped before overwrite)

### Backup Locations

1. **Time Machine** on your Mac
2. **ZFS snapshots** on miniserver99 (automatic)
3. **Encrypted in Git** via `secrets/static-leases-miniserver99.age`
4. **1Password** (optional: store backup copy)

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
- 115+ static DHCP lease assignments (declarative)
- Custom DHCP options
- Integration with DNS resolution

### Administration
- Web interface: http://192.168.1.99:3000
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
- ✅ DHCP enabled with 115+ static leases
- ✅ DNS rewrites for internal hosts
- ✅ Repository cloned to ~/Code/nixcfg on miniserver99
- ✅ Admin credentials configured

### Notes
- All configuration is declarative (`mutableSettings = false`)
- Static leases file is gitignored (contains sensitive network data)
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

- **AdGuard Home Documentation**: https://github.com/AdguardTeam/AdGuardHome/wiki
- **NixOS Manual**: https://nixos.org/manual/nixos/stable/
- **Disko (ZFS setup)**: https://github.com/nix-community/disko
- **nixos-anywhere**: https://github.com/nix-community/nixos-anywhere
- **agenix (secrets)**: https://github.com/ryantm/agenix
