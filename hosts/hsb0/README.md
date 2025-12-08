# hsb0 - DNS/DHCP Server

## Purpose

Primary DNS and DHCP server running **AdGuard Home** as a native NixOS service, replacing the Pi-hole setup from miniserver24.

## Quick Reference

| Item                  | Value                                                |
| --------------------- | ---------------------------------------------------- |
| **Hostname**          | `hsb0`                                               |
| **Model**             | Mac mini 2011                                        |
| **CPU**               | Intel Core i5-2415M @ 2.30GHz (2C/4T)                |
| **RAM**               | 8 GB (7.7 GiB usable)                                |
| **Storage**           | 250 GB Samsung SSD 840 Series (232.9 GB)             |
| **Filesystem**        | ZFS (zroot pool, 3% used)                            |
| **Static IP**         | `192.168.1.99/24`                                    |
| **Gateway**           | `192.168.1.5` (Fritz!Box)                            |
| **DNS**               | `127.0.0.1` (local AdGuard Home)                     |
| **DHCP Range**        | `192.168.1.201` - `192.168.1.254`                    |
| **Web Interface**     | [http://192.168.1.99:3000](http://192.168.1.99:3000) |
| **SSH Access**        | `ssh mba@192.168.1.99` or `ssh mba@hsb0.lan`         |
| **Network Interface** | `enp2s0f0`                                           |
| **ZFS Host ID**       | `dabfdb02`                                           |
| **User**              | `mba` (Markus Barta)                                 |
| **Role**              | `server-home` (via `serverMba.enable`)               |
| **Exposure**          | LAN-only (192.168.1.0/24)                            |

## Features

hsb0 provides comprehensive DNS/DHCP infrastructure for the entire network:

| ID  | Technical                             | User-Friendly                                          | Test |
| --- | ------------------------------------- | ------------------------------------------------------ | ---- |
| F00 | NixOS Base System                     | Stable system foundation with generation management    | T00  |
| F01 | AdGuard Home DNS Server               | Fast DNS resolution with Cloudflare upstream           | T01  |
| F02 | AdGuard Home Ad Blocking              | Block ads and trackers across all network devices      | T02  |
| F03 | DNS Cache (4MB)                       | Faster DNS lookups with optimistic caching             | T03  |
| F04 | DHCP Server (192.168.1.201-254)       | Automatic IP assignment for new devices                | T04  |
| F05 | Static DHCP Leases (agenix-encrypted) | Fixed IPs for infrastructure (servers, printers, etc.) | T05  |
| F06 | DNS Rewrites (csb0 → cs0.barta.cm)    | Short names for cloud servers                          | T06  |
| F07 | Web Management Interface (port 3000)  | Admin UI for DNS/DHCP management                       | T07  |
| F08 | DNS Query Logging (90 days)           | Track DNS queries for troubleshooting                  | T08  |
| F09 | SSH Remote Access + Security          | Secure SSH with key-only auth, passwordless sudo       | T09  |
| F10 | ZFS Storage (zroot pool)              | Reliable storage with compression & snapshots          | T10  |
| F11 | ZFS Snapshots                         | Point-in-time backups for disaster recovery            | T11  |
| F12 | APC UPS Monitoring + MQTT             | Power protection status published to home automation   | T16  |
| F13 | Uptime Kuma Service Monitoring        | Web UI for monitoring service uptime                   | T15  |

**Test Documentation**: All features have detailed test procedures in `hosts/hsb0/tests/` with both manual instructions and automated scripts.

## Firewall Ports

- **TCP 53**: DNS queries
- **UDP 53**: DNS queries
- **UDP 67**: DHCP server
- **TCP 3000**: AdGuard Home web interface
- **TCP 22**: SSH
- **TCP 3001**: Uptime Kuma web interface
- **TCP 80/443**: Reserved for future use

---

## Hardware Specifications

### System Details

- **Model**: Mac mini 2011 (Intel-based)
- **CPU**: Intel Core i5-2415M @ 2.30GHz
  - 2 cores, 4 threads (2 threads per core)
  - Sandy Bridge architecture (2nd generation)
- **RAM**: 8 GB DDR3 (7.7 GiB usable)
- **Storage**: Samsung SSD 840 Series
  - **Type**: SSD (Solid State Drive)
  - **Capacity**: 250 GB (232.9 GB usable)
  - **Interface**: SATA
  - **Status**: Non-rotating (ROTA=0), confirmed SSD
- **Network**: Gigabit Ethernet (enp2s0f0)

### Software

- **OS**: NixOS 25.11 (Xantusia)
- **Kernel**: Linux 6.17.8
- **Architecture**: x86_64 GNU/Linux
- **ZFS Host ID**: `dabfdb02`
- **Uptime**: 7+ days (highly stable)

### Disk Layout

```text
NAME     SIZE   TYPE  MOUNTPOINT        ROTA  MODEL
sda      232.9G disk                    0     Samsung SSD 840 Series
├─sda1   1M     part  (BIOS boot)       0
├─sda2   500M   part  /boot             0
└─sda3   232.4G part  (ZFS zroot)       0
zram0    3.8G   disk  [SWAP]            0
```

### ZFS Configuration

```text
Pool: zroot
Size: 232 GB total
Allocated: 8.89 GB (3% used)
Free: 223 GB available
State: ONLINE (healthy)
Health: No known data errors
Disk: disk-disk1-zfs (232.4 GB)
Fragmentation: 5%
Dedup: 1.00x (disabled)
Compression: Enabled (lz4)

Filesystems:
- zroot/root  → /      (system root)
- zroot/nix   → /nix   (Nix store)
- zroot/home  → /home  (user data)
```

---

## Installation

### Prerequisites

- ✅ **Boot Media**: USB stick with NixOS minimal ISO (nixos-minimal-25.05 or later)
- ✅ **Source Machine**: miniserver24 (192.168.1.101) or your Mac
- ✅ **Network**: All machines on same network (192.168.1.x)
- ✅ **Static Lease Data**: Encrypted in `secrets/static-leases-hsb0.age` (managed by agenix)

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
  --flake .#hsb0 \
  root@192.168.1.150
```

**From your Mac:**

```bash
cd ~/Code/nixcfg

# Deploy
nix run github:nix-community/nixos-anywhere -- \
  --flake .#hsb0 \
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
# On hsb0
cd ~/Code/nixcfg
git pull
just switch
```

### Useful Justfile Commands

```bash
# Switch configuration
just switch

# Edit static leases (using agenix)
just edit-secret secrets/static-leases-hsb0.age

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

All 107 static DHCP leases are managed using **agenix** (encrypted secrets). The encrypted file `secrets/static-leases-hsb0.age` contains a **JSON array** that is:

- ✅ **Single Source of Truth**: The `.age` file in git is the canonical source
- ✅ **Encrypted**: Uses dual-key encryption (your SSH key + hsb0 host key)
- ✅ **Automatic Decryption**: Agenix decrypts to `/run/agenix/static-leases-hsb0` at system activation
- ✅ **Runtime Loading**: preStart script reads JSON and merges into AdGuard's leases database
- ✅ **Build-time Independent**: No import at Nix evaluation time - works correctly!

### How It Works - Complete Flow

```text
1. Edit (Your Mac)
   └─> agenix -e secrets/static-leases-hsb0.age
       └─> Opens editor with JSON
       └─> Save → re-encrypts → commit to git

2. Deploy (hsb0)
   └─> just switch
       └─> NixOS builds configuration (no static leases needed yet!)
       └─> System activation
           └─> Agenix decrypts all secrets
               └─> Writes /run/agenix/static-leases-hsb0

      3. Service Start (hsb0)
         └─> AdGuard Home starts
             └─> preStart script executes
                 ├─> Reads /run/agenix/static-leases-hsb0
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
agenix -e secrets/static-leases-hsb0.age

# Your editor opens with the decrypted JSON
# Make changes, save, exit → automatically re-encrypted
```

**Validate JSON locally:**

```bash
# Before deploying, you can validate
agenix -d secrets/static-leases-hsb0.age | jq empty
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
# On hsb0
sudo jq '.leases[] | select(.static == true)' \
  /var/lib/private/AdGuardHome/data/leases.json
```

### Security Model - Dual-Key Encryption

**Implementation Date:** November 15, 2025

Static leases are encrypted with **two keys** in `secrets/secrets.nix`:

```nix
"static-leases-hsb0.age".publicKeys = markus ++ hsb0;
```

**What this means:**

1. **Your personal key** (`markus`) - Edit from Mac or any machine with your SSH key
2. **hsb0 host key** - System can decrypt at activation (no manual intervention)

**Key locations:**

- Personal key: `~/.ssh/id_rsa` (or `id_ed25519`, `id_ecdsa`)
- Host key: `/etc/ssh/ssh_host_ed25519_key` (on hsb0)

**Benefits:**

- ✅ Edit secrets from your Mac without being on the server
- ✅ Server can decrypt automatically during `nixos-rebuild`
- ✅ No plaintext files ever stored in git
- ✅ Lost personal key? Server can still decrypt with its host key

### Backup Locations

The static leases are backed up in multiple locations:

1. **Git Repository** - `secrets/static-leases-hsb0.age` (encrypted, primary backup)
2. **GitHub** - Pushed to remote repository
3. **Time Machine** on your Mac (includes git repo)
4. **ZFS snapshots** on hsb0 (decrypted file in `/run/agenix/`)
5. **Optional**: 1Password (store a backup copy of the `.age` file)

### Error Handling & Troubleshooting

**Service fails to start:**

```bash
# Check the preStart script output
sudo journalctl -u adguardhome -n 50

# Common errors:
# "ERROR: Static leases file not found" → agenix didn't decrypt (check age.secrets config)
# "ERROR: Invalid JSON" → Fix with: agenix -e secrets/static-leases-hsb0.age
```

**Validate before deploying:**

```bash
# Test JSON format locally
agenix -d secrets/static-leases-hsb0.age | jq empty

# Count entries
agenix -d secrets/static-leases-hsb0.age | jq 'length'
```

**Rollback if needed:**

```bash
# Revert to previous configuration
sudo nixos-rebuild switch --rollback

# Or restore from git history
git log secrets/static-leases-hsb0.age
git show COMMIT:secrets/static-leases-hsb0.age > /tmp/restored.age
```

### Migration from Nix to JSON Format

**If you have an existing Nix-format `.age` file, convert it:**

```bash
# 1. Read the current Nix file
cat hosts/hsb0/static-leases.nix

# 2. Convert to JSON using nix-instantiate
nix-instantiate --eval --strict --json -E '
  let data = import ./hosts/hsb0/static-leases.nix;
  in data.static_leases
' | jq '.' > /tmp/static-leases.json

# 3. Encrypt the JSON with agenix
agenix -e secrets/static-leases-hsb0.age
# (paste the JSON content, save, exit)

# 4. Verify
agenix -d secrets/static-leases-hsb0.age | jq empty

# 5. Deploy
git add secrets/static-leases-hsb0.age
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

### SSH Host Keys (hsb0)

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
- Custom DHCP options fully supported (✅ verified working with AdGuard Home v0.107.65)
- Integration with DNS resolution

### Search Domain Configuration (✅ Working)

**Status:** DHCP Option 15 (domain name/search domain) is configured declaratively and **successfully transmitted** by AdGuard Home v0.107.65.

**Configuration:**

```nix
services.adguardhome.settings.dhcp.dhcpv4.options = [
  "15 text lan"
];
```

**Result:** All DHCP clients automatically receive the `.lan` search domain and can access local hosts by short hostname (e.g., `http://vr-shelly-pro-4-heizung1` works without the `.lan` suffix).

**Verification:** You can confirm Option 15 is being transmitted by capturing DHCP traffic:

```bash
# On the server
ssh mba@192.168.1.99 "sudo tcpdump -i enp2s0f0 -vvv -n 'udp port 67 or udp port 68' -c 4"

# Then renew DHCP lease on a client
# Look for: Domain-Name (15), length 3: "lan"
```

**Tested and confirmed working on:**

- macOS (shows "lan" as default search domain in System Settings)
- Apple Airport devices (verified in packet captures)
- Other DHCP clients (option transmitted to all)

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
- **Uptime Kuma**: Service monitoring (port 3001)
- **Firewall**: iptables/nftables packet filtering

---

## APC UPS Monitoring

### Overview

hsb0 monitors a USB-connected **APC Back-UPS ES 350** and publishes status to MQTT every minute for home automation integration. The UPS provides power protection for critical network infrastructure (DNS/DHCP server).

| Item                 | Value                                      |
| -------------------- | ------------------------------------------ |
| **UPS Model**        | APC Back-UPS ES 350                        |
| **Connection**       | USB                                        |
| **Daemon**           | `apcupsd` (NixOS native)                   |
| **MQTT Topic**       | `home/vr/battery/ups350`                   |
| **MQTT Broker**      | hsb1 (192.168.1.101)                       |
| **Publish Interval** | Every 1 minute                             |
| **Credentials**      | Agenix-encrypted (`secrets/mqtt-hsb0.age`) |

### Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│ hsb0 (192.168.1.99)                                         │
├─────────────────────────────────────────────────────────────┤
│  USB ──► apcupsd daemon ──► apcaccess status               │
│                                    │                        │
│            ┌───────────────────────┘                        │
│            ▼                                                │
│  systemd timer (1min) ──► ups-mqtt-publish.service         │
│                                    │                        │
│            ┌───────────────────────┘                        │
│            ▼                                                │
│  /run/agenix/mqtt-hsb0 ──► mosquitto_pub                   │
│            │                                                │
└────────────│────────────────────────────────────────────────┘
             │
             ▼ MQTT: home/vr/battery/ups350
┌─────────────────────────────────────────────────────────────┐
│ hsb1 (192.168.1.101) - Mosquitto Broker                    │
│     └─► Node-RED / Home Assistant / Automations            │
└─────────────────────────────────────────────────────────────┘
```

### JSON Payload Example

The service publishes UPS status as JSON to the MQTT broker:

```json
{
  "apc": "001,036,0890",
  "date": "2025-12-02 19:30:00 +0100",
  "hostname": "hsb0",
  "version": "3.14.14",
  "upsname": "ups350vr",
  "cable": "USB Cable",
  "driver": "USB UPS Driver",
  "upsmode": "Stand Alone",
  "status": "ONLINE",
  "linev": "230.0 Volts",
  "loadpct": "12.0 Percent",
  "bcharge": "100.0 Percent",
  "timeleft": "45.0 Minutes",
  "mbattchg": "5 Percent",
  "mintimel": "3 Minutes",
  "battv": "13.5 Volts",
  "lastxfer": "No transfers since turnon",
  "__published": 1733166600000
}
```

### Configuration

**NixOS configuration** (`configuration.nix`):

```nix
# APC UPS daemon
services.apcupsd = {
  enable = true;
  configText = ''
    UPSCABLE usb
    UPSTYPE usb
    DEVICE
    UPSNAME ups350vr
  '';
};

# MQTT credentials (agenix-encrypted)
age.secrets.mqtt-hsb0 = {
  file = ../../secrets/mqtt-hsb0.age;
  mode = "400";
};

# Systemd service + timer for MQTT publishing
systemd.services.ups-mqtt-publish = { ... };
systemd.timers.ups-mqtt-publish = {
  timerConfig.OnUnitActiveSec = "1min";
};
```

**MQTT credentials** (`secrets/mqtt-hsb0.age`):

```bash
# Edit with: agenix -e secrets/mqtt-hsb0.age
MQTT_HOST=hsb1.lan
MQTT_USER=smarthome
MQTT_PASS=<password>
```

### Useful Commands

```bash
# Check UPS status directly
apcaccess status

# Check service status
systemctl status ups-mqtt-publish
systemctl status apcupsd

# View recent MQTT publications
journalctl -u ups-mqtt-publish -n 20

# Manually trigger a publish
sudo systemctl start ups-mqtt-publish

# Subscribe to MQTT topic (for testing)
mosquitto_sub -h hsb1.lan -u smarthome -P '<password>' -t 'home/vr/battery/ups350'
```

### Migration History

This UPS was previously connected to a Raspberry Pi (`raspi01` at 192.168.1.95) with:

- Cron job running every minute
- Plain text `.env` file for MQTT credentials
- External bash script in `/home/mba/scripts/`

The new NixOS implementation provides:

| Aspect       | Raspi (old)                   | hsb0 (new)                   |
| ------------ | ----------------------------- | ---------------------------- |
| Secrets      | Plain text `.env` in home dir | Agenix-encrypted in git      |
| Scheduler    | Cron                          | systemd timer                |
| Script       | External file                 | Inline in Nix (reproducible) |
| Dependencies | Manual apt install            | Declarative Nix packages     |
| Audit trail  | None                          | Git history                  |

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
   - Deployed hsb0 at 192.168.1.99
   - Configured AdGuard Home with all static leases
   - Added equivalent blocklists from Pi-hole
   - Verified configuration

2. **Cutover (Evening, Low Traffic):**
   - Stopped Pi-hole container on miniserver24
   - hsb0 took over DNS/DHCP immediately
   - **Minimal downtime**: ~2-3 minutes while services switched
   - No manual DHCP renewal needed (24-hour lease time meant clients renewed automatically)

3. **Post-Cutover:**
   - Monitored AdGuard Home query logs for first 24 hours
   - No client issues encountered
   - All devices received correct IPs via static leases

### Why Parallel Testing Wasn't Feasible

Both Pi-hole (miniserver24) and AdGuard Home (hsb0) were configured for **192.168.1.99**, so running them simultaneously would cause IP conflicts. The solution was a quick cutover instead.

### Rollback Plan (If Needed)

**Quick Rollback:**

```bash
# Stop AdGuard Home on hsb0
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
- ✅ Repository cloned to ~/Code/nixcfg on hsb0
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
- Uptime Kuma service monitoring
- Firmware updates (fwupd)

### Excluded

- No graphical environment
- No audio subsystem
- No desktop applications
- No IoT/home automation
- No media services

---

## Changelog

### 2025-12-02: APC UPS Monitoring Added

- **Migrated UPS from Raspberry Pi** (`raspi01`) to hsb0
  - USB-connected APC Back-UPS ES 350
  - NixOS native `apcupsd` service
  - systemd timer for MQTT publishing (every 1 minute)
  - Agenix-encrypted MQTT credentials
- **MQTT integration** with hsb1 broker
  - Topic: `home/vr/battery/ups350`
  - JSON payload with full UPS status
- **Improved over Raspi setup**:
  - No more plain text credentials
  - Declarative, reproducible configuration
  - Full audit trail in git

### 2025-11-22: Test Suite Created

- **Added comprehensive test suite** (12 features, 24 test files)
  - T00-T11: Manual test procedures (`.md` files)
  - T00-T11: Automated test scripts (`.sh` files)
  - Test overview with tracking table (`tests/README.md`)
- **Created Features table** in README for quick reference
- **Test coverage**:
  - System foundation (NixOS, ZFS)
  - DNS/DHCP services (AdGuard Home)
  - Ad blocking, caching, query logging
  - Static DHCP leases (agenix-encrypted)
  - DNS rewrites (csb0/csb1)
  - Web management interface
  - SSH access and security
  - ZFS storage and snapshots

### 2025-11-21: Hostname Migration Completed

- Renamed from `miniserver99` to `hsb0`
- Updated all documentation and configuration references
- System running stable with new hostname

### 2025-11-XX: Initial DNS/DHCP Deployment

- Replaced Pi-hole on miniserver24
- Deployed AdGuard Home as native NixOS service
- Cutover completed successfully

---

## Additional Resources

- **AdGuard Home Documentation**: [https://github.com/AdguardTeam/AdGuardHome/wiki](https://github.com/AdguardTeam/AdGuardHome/wiki)
- **NixOS Manual**: [https://nixos.org/manual/nixos/stable/](https://nixos.org/manual/nixos/stable/)
- **Disko (ZFS setup)**: [https://github.com/nix-community/disko](https://github.com/nix-community/disko)
- **nixos-anywhere**: [https://github.com/nix-community/nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
- **agenix (secrets)**: [https://github.com/ryantm/agenix](https://github.com/ryantm/agenix)
