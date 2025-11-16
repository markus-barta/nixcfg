# mba-msww87 Server - System Analysis & Setup Notes

**Date**: November 16, 2025  
**Current Status**: 🟡 Running with DHCP, needs static IP configuration

---

## Quick Reference

- **Hostname**: `mba-msww87`
- **Location**: Parents' home (next to Markus)
- **Current IP**: `192.168.1.223` (DHCP - dynamic)
- **Planned IP**: `192.168.1.100` (static - **AVAILABLE**)
- **Network Interface**: `enp2s0f0`
- **SSH Access**: `ssh mba@192.168.1.223` (will be `ssh mba@192.168.1.100` after config)
- **Boot Time**: Sun Nov 16 12:32 CET (just rebooted ~5 min ago)

---

## System Information

### Hardware

- **Model**: Mac mini (Intel, likely 2011 model based on i5-2415M)
- **CPU**: Intel Core i5-2415M @ 2.30GHz (2 cores, 4 threads, Sandy Bridge)
- **RAM**: 7.7 GB (8GB installed)
- **Storage**: 111.8 GB SSD (sda)
- **Network**: Gigabit Ethernet (enp2s0f0)

### Software

- **OS**: NixOS 25.11.20250819.2007595 (Xantusia)
- **Kernel**: Linux 6.15.10 #1-NixOS SMP PREEMPT_DYNAMIC
- **Architecture**: x86_64 GNU/Linux
- **ZFS Host ID**: `cdbc4e20` (configured in flake)
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
Errors: None

Filesystems:
- zroot/root  → / (896 KB used)
- zroot/nix   → /nix (2.5 GB used)
- zroot/home  → /home (4.0 MB used)
- zroot       → /zroot (128 KB used)

Available: 106 GB free
```

---

## Network Configuration

### Current State (DHCP)

```
Interface: enp2s0f0
IP Address: 192.168.1.223/24 (dynamic from AdGuard Home)
Gateway: 192.168.1.5 (vr-fritz-box)
DNS: 192.168.1.99 (miniserver99 / AdGuard Home)
Status: UP, RUNNING
```

### Required Changes

**⚠️ NEEDS STATIC IP CONFIGURATION**

The hardware-configuration.nix references `enp3s0f0` in comments, but the actual interface is `enp2s0f0` (verified via `ip addr`).

**Configuration to add** to `hosts/mba-msww87/configuration.nix`:

```nix
networking = {
  # DNS and gateway configuration
  nameservers = [
    "192.168.1.99"  # miniserver99 / AdGuard Home
    "1.1.1.1"       # Cloudflare fallback
  ];
  search = [ "lan" ];
  defaultGateway = "192.168.1.5";

  # Static IP configuration - CORRECT INTERFACE: enp2s0f0
  interfaces.enp2s0f0 = {
    ipv4.addresses = [
      {
        address = "192.168.1.100";
        prefixLength = 24;
      }
    ];
  };

  firewall = {
    allowedTCPPorts = [
      80    # HTTP
      443   # HTTPS
      8883  # MQTT
    ];
    allowedUDPPorts = [
      443   # HTTPS
    ];
  };
};
```

---

## Running Services

### Core System Services

- ✅ **sshd.service** - SSH Daemon (port 22)
- ✅ **docker.service** - Docker Application Container Engine
- ✅ **fail2ban.service** - Intrusion prevention
- ✅ **NetworkManager.service** - Network management
- ✅ **nix-daemon.service** - Nix package manager
- ✅ **systemd-timesyncd.service** - NTP time sync
- ✅ **zfs-zed.service** - ZFS Event Daemon

### Docker Status

- **Status**: Running and enabled
- **Containers**: None currently running
- **Network**: Docker bridge at 172.17.0.1/16
- **Purpose**: Ready for home automation containers

### Network Services

**Listening Ports:**

- TCP 22 (SSH) - 0.0.0.0 and [::]

**Firewall Configuration:**

- Configured to allow: 80, 443, 8883 (TCP), 443 (UDP)
- Currently using firewall rules from NixOS config

---

## User Configuration

### Users

- **mba** - Primary user (UID 1000)
  - SSH access configured
  - Home directory: /home/mba
  - Currently logged in from 192.168.1.150

- **gb** - Secondary user (Gerhard)
  - SSH access configured ✅ (Nov 16, 2025)
  - Public key: `ssh-rsa ...Gerhard@imac-gb.local`
  - Can connect via: `ssh gb@mba-msww87.lan`

---

## Repository Status

### nixcfg Repository

❌ **NOT CLONED** - needs setup

**Action Required:**

```bash
ssh mba@192.168.1.223
mkdir -p ~/Code
cd ~/Code
git clone https://github.com/your-username/nixcfg.git
cd nixcfg
```

---

## IP Address Analysis - 192.168.1.100

### Investigation Results

✅ **192.168.1.100 is AVAILABLE** for use

**Checked locations:**

1. ✅ miniserver99 (192.168.1.99) - AdGuard Home DHCP leases: NO assignment
2. ✅ miniserver24 (192.168.1.101) - Pi-hole configs: Legacy entries only (Pi-hole not running)
3. ✅ NixOS configurations: Only found in documentation examples and commented code

**Historical Usage (Pi-hole - INACTIVE):**

- Pi-hole on miniserver24 had .100 configured as:
  - DNS alias for "mosquitto" / "mosquitto.lan"
  - Static DHCP with fake MAC `FF:00:00:00:00:00`
  - Also aliased: miniserver, nodered-homekit, grafana, influxdb

**Current Status:**

- Pi-hole is NOT running (migrated to AdGuard Home)
- MQTT broker (mosquitto) actually runs on miniserver24 at 192.168.1.101
- No physical device or service actively using .100

**Conclusion:** Safe to assign 192.168.1.100 to mba-msww87

---

## Purpose & Role

**Primary Function:** Home automation server at parents' home

**Planned Services:**

- Node-RED for automation flows
- MQTT broker (Mosquitto) - port 8883
- HomeKit bridge integration
- Monitoring and logging
- Docker-based services

**Similar to:** miniserver24 (home automation hub) but deployed remotely

---

## Next Steps / TODO

### Immediate Tasks

1. **[ ] Switch Repository to Your Fork**
   - **PRIORITY**: Must be done before other changes
   - Current: `https://github.com/pbek/nixcfg.git` (friend's repo, 235 commits behind)
   - Target: `https://github.com/markus-barta/nixcfg.git` (your fork, current)
   - Guide: [`docs/temporary/mba-msww87-repo-switch-guide.md`](./mba-msww87-repo-switch-guide.md)
   - Includes: Safe migration plan with rollback options

2. **[ ] Configure Static IP**
   - Update `hosts/mba-msww87/configuration.nix` with static IP config
   - Fix interface name from `enp3s0f0` to `enp2s0f0`
   - Deploy via `nixos-rebuild switch`

3. **[ ] Add Static DHCP Lease on miniserver99**
   - Get MAC address: `ssh mba@192.168.1.223 "ip link show enp2s0f0 | grep link/ether"`
   - Add to `secrets/static-leases-miniserver99.age`
   - Format: `{"mac": "XX:XX:XX:XX:XX:XX", "ip": "192.168.1.100", "hostname": "mba-msww87"}`
   - Note: Done via repo switch (step 1)

4. **[ ] Update Documentation**
   - Add mba-msww87 to `docs/how-it-works.md`
   - Update network diagram with .100 assignment

### Configuration Improvements

5. **[✅] Add Gerhard's SSH Public Key** (Nov 16, 2025)
   - ✅ Public key added from ~/Downloads/id_rsa.pub
   - ✅ Configured in `users.users.gb.openssh.authorizedKeys.keys`
   - 📋 Needs deployment: `just switch` on mba-msww87

6. **[ ] Configure Services**
   - Decide which home automation services to run
   - Set up Docker compose files if needed
   - Configure MQTT broker

7. **[ ] Monitoring & Backups**
   - Add to monitoring system (if applicable)
   - Configure ZFS snapshot schedule
   - Set up remote backup strategy

---

## System Access

### SSH Connection

**Current (temporary):**

```bash
ssh mba@192.168.1.223
```

**After static IP configuration:**

```bash
ssh mba@192.168.1.100
ssh mba@mba-msww87.lan  # via DNS
```

### Managing the System

```bash
# Rebuild system after config changes
just switch

# Update system
just upgrade

# View logs
journalctl -f

# Check ZFS status
zpool status
zfs list

# Check Docker containers
docker ps -a

# Check network
ip addr show enp2s0f0
ss -tlnp
```

---

## Notes

### Recent Activity

- System was installed on **August 23, 2025** (first boot in wtmp)
- Rebooted today: **November 16, 2025 at 12:32 CET**
- Current uptime: ~5 minutes (fresh boot)
- Previous session: Aug 23 17:35-17:56 (20 minutes) - likely testing/setup

### Hardware Notes

- Mac mini 2011 model (Intel i5 Sandy Bridge)
- Broadcom wireless driver reference in config (currently unused)
- Using wired Ethernet connection
- 8GB RAM is adequate for home automation tasks
- 112GB SSD provides ample space for Docker containers and logs

### Configuration Notes

- ZFS enabled with encryption support
- Server role: `serverMba.enable = true`
- Includes standard server security (fail2ban, firewall)
- Docker pre-installed and ready
- Network time sync active

---

## Related Documentation

- [Main README](../../README.md) - Repository overview
- [How It Works](../how-it-works.md) - Architecture and machine inventory
- [miniserver99 README](../../hosts/miniserver99/README.md) - DNS/DHCP server setup
- [miniserver24 Config](../../hosts/miniserver24/configuration.nix) - Similar home automation setup

---

## Changelog

- **2025-11-16**: Initial system analysis and documentation
  - Discovered running at 192.168.1.223 (DHCP)
  - Verified .100 IP is available
  - Identified interface name discrepancy (enp2s0f0 vs enp3s0f0)
  - Documented required configuration changes
