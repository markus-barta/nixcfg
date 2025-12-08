# hsb1 - Home Automation Server

## Purpose

Home automation hub running Node-RED, Zigbee2MQTT, MQTT broker, and related services.

## Quick Reference

| Item                               | Value                                                    |
| ---------------------------------- | -------------------------------------------------------- |
| **Hostname**                       | `hsb1`                                                   |
| **Model**                          | Mac mini 2014 (Late 2014)                                |
| **CPU**                            | Intel Core i7-4578U @ 3.00GHz (2C/4T)                    |
| **RAM**                            | 16 GB (15 GiB usable)                                    |
| **Storage**                        | 512 GB Apple SSD (465.9 GB usable)                       |
| **Filesystem**                     | ZFS (zroot pool, 12% used)                               |
| **Static IP**                      | `192.168.1.101/24`                                       |
| **Gateway**                        | `192.168.1.5` (Fritz!Box)                                |
| **DNS**                            | `192.168.1.99` (hsb0) + `1.1.1.1` (fallback)             |
| **Web Interface - Node-RED**       | [http://192.168.1.101:1880](http://192.168.1.101:1880)   |
| **Web Interface - Zigbee2MQTT**    | [http://192.168.1.101:8888](http://192.168.1.101:8888)   |
| **Web Interface - Apprise**        | [http://192.168.1.101:8001](http://192.168.1.101:8001)   |
| **SSH Access**                     | `ssh mba@192.168.1.101` or `ssh mba@hsb1.lan`            |
| **Network Interface**              | `enp3s0f0`                                               |
| **ZFS Host ID**                    | `dabfdb01`                                               |
| **User**                           | `mba` (Markus Barta)                                     |
| **Role**                           | `server-home` (via `serverMba.enable`)                   |
| **Exposure**                       | LAN-only (192.168.1.0/24)                                |
| **Web Interface - Home Assistant** | [http://192.168.1.101:8123](http://192.168.1.101:8123)   |
| **Web Interface - Scrypted**       | [http://192.168.1.101:10443](http://192.168.1.101:10443) |

## Features

| ID  | Technical               | User-Friendly                                 | Test |
| --- | ----------------------- | --------------------------------------------- | ---- |
| F00 | NixOS Base System       | Stable system foundation with generation mgmt | T00  |
| F01 | Node-RED                | Home automation flows and logic               | T04  |
| F02 | Zigbee2MQTT             | Zigbee device management                      | T04  |
| F03 | MQTT Broker (Mosquitto) | Message broker for IoT devices                | T04  |
| F04 | Home Assistant          | Main home automation hub                      | T04  |
| F05 | Scrypted                | Camera/NVR/HomeKit bridge                     | T04  |
| F06 | VLC Kiosk Mode          | Camera viewing on connected display           | -    |
| F07 | APC UPS Monitoring      | UPS status via MQTT                           | -    |
| F08 | ZFS Storage             | Reliable storage with compression & snapshots | -    |

---

## Configuration Management

### Deploying Changes

```bash
# On hsb1
cd ~/Code/nixcfg
git pull
just switch
```

### Useful Justfile Commands

```bash
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
- [Runbook](../../docs/RUNBOOK-hsb1.md) - Operational procedures

---

## Network Configuration

### DNS Resolution

- **Primary DNS**: hsb0 (192.168.1.99) running AdGuard Home
- **Fallback DNS**: Cloudflare (1.1.1.1)
- **Managed by**: NetworkManager (NixOS configured nameservers)
- **Docker containers**: Inherit DNS from host `/etc/resolv.conf`

### Static Hosts

Custom DNS entries for devices without proper DHCP hostnames:

- `192.168.1.32` - kr-sonnen-batteriespeicher (solar battery)
- `192.168.1.102` - vr-opus-gateway (voice assistant)
- `192.168.1.159` - wz-pixoo-64-00 (display)
- `192.168.1.189` - wz-pixoo-64-01 (display)

### Firewall

**Status**: Disabled (HomeKit compatibility issues)

If re-enabled, open ports: 80, 443, 1880, 1883, 5223, 5353, 9000, 51827, 554

Note: fail2ban also disabled. This is acceptable for LAN-only server.

---

## Hardware Specifications

### System Details

- **Model**: Mac mini Late 2014 (Intel-based)
- **CPU**: Intel Core i7-4578U @ 3.00GHz
  - 2 cores, 4 threads (2 threads per core)
  - Haswell architecture (4th generation)
  - **Higher performance** than hsb0/hsb8 (i7 vs i5)
- **RAM**: 16 GB DDR3 (15 GiB usable)
  - **Double the RAM** of hsb0/hsb8
- **Storage**: Apple SSD SM0512G
  - **Type**: SSD (Solid State Drive)
  - **Capacity**: 512 GB (465.9 GB usable)
  - **Interface**: PCIe (faster than SATA)
  - **Status**: Non-rotating (ROTA=0), confirmed SSD
  - **Largest capacity** of all three servers
- **Network**: Gigabit Ethernet (enp3s0f0)
- **Bluetooth**: Enabled
- **USB**: FLIRC IR-USB receiver, APC UPS connected

### Software

- **OS**: NixOS 25.11 (Xantusia)
- **Kernel**: Linux 6.17.8
- **Architecture**: x86_64 GNU/Linux
- **ZFS Host ID**: `dabfdb01`
- **Uptime**: Long-running (home automation requires stability)

### Disk Layout

```text
NAME     SIZE   TYPE  MOUNTPOINT        ROTA  MODEL
sda      465.9G disk                    0     APPLE SSD SM0512G
├─sda1   1M     part  (BIOS boot)       0
├─sda2   500M   part  /boot             0
└─sda3   465.4G part  (ZFS zroot)       0
zram0    7.8G   disk  [SWAP]            0
```

### ZFS Configuration

```text
Pool: zroot
Size: 464 GB total
Allocated: 59.9 GB (12% used)
Free: 404 GB available
State: ONLINE (healthy)
Health: No known data errors
Disk: wwn-0x5002538900000000-part3 (465.4 GB)
Fragmentation: 55% (higher due to active use)
Dedup: 1.00x (disabled)
Compression: Enabled (lz4)

Filesystems:
- zroot/root  → /      (system root)
- zroot/nix   → /nix   (Nix store)
- zroot/home  → /home  (user data)
```

### Performance Comparison

| Feature         | hsb1                    | hsb0                   | hsb8                   |
| --------------- | ----------------------- | ---------------------- | ---------------------- |
| **CPU**         | i7-4578U @ 3.00GHz      | i5-2415M @ 2.30GHz     | i5-2415M @ 2.30GHz     |
| **Generation**  | 4th gen (Haswell)       | 2nd gen (Sandy Bridge) | 2nd gen (Sandy Bridge) |
| **RAM**         | 16 GB (2x others)       | 8 GB                   | 8 GB                   |
| **Storage**     | 512 GB Apple SSD (PCIe) | 250 GB Samsung (SATA)  | 120 GB Kingston (SATA) |
| **Performance** | Best                    | Good                   | Good                   |

**hsb1 is the most powerful server** in the home infrastructure, making it ideal for home automation, Docker containers, and demanding services.

---

## Docker Containers

All containers run with host network access and DNS resolution:

| Container               | Purpose                    | Ports      |
| ----------------------- | -------------------------- | ---------- |
| **homeassistant**       | Main automation hub        | 8123       |
| **nodered**             | Home automation flows      | 1880       |
| **mosquitto**           | MQTT broker                | 1883, 9001 |
| **zigbee2mqtt**         | Zigbee bridge              | 8888       |
| **scrypted**            | Camera/NVR/HomeKit bridge  | 10443      |
| **matter-server**       | Matter protocol            | 5580       |
| **pidicon**             | Pixoo display control      | 10829      |
| **apprise**             | Notifications              | 8001       |
| **opus-stream-to-mqtt** | OPUS gateway → MQTT bridge | -          |
| **smtp**                | Mail relay                 | 25         |
| **restic-cron-hetzner** | Backups to Hetzner         | -          |
| **watchtower-weekly**   | Weekly auto-updates        | -          |
| **watchtower-pidicon**  | Fast pidicon updates       | -          |

## Native Services

- **APC UPS Monitoring**: USB-connected UPS with MQTT status publishing (every 1 min)
- **VLC Kiosk Mode**: Auto-login `kiosk` user for camera viewing (fullscreen)
- **MQTT Volume Control**: Controls VLC volume via MQTT topic `home/hsb1/kiosk-vlc-volume`
- **ZFS**: Auto-scrubbing enabled
- **FLIRC IR-USB**: Remote control support
- **Bluetooth**: Enabled

## Relationship with hsb0

hsb1 depends on hsb0 for:

- **DNS Resolution**: All DNS queries → AdGuard Home (192.168.1.99)
- **DHCP**: Static lease assigned by hsb0
- **Ad-blocking**: Network-wide filtering via AdGuard Home

If hsb0 is down:

- DNS falls back to Cloudflare (1.1.1.1)
- Static IP remains functional
- Ad-blocking unavailable

---

## Useful Commands

```bash
# Check DNS resolution
dig @192.168.1.99 google.com
cat /etc/resolv.conf

# Docker containers
docker ps
docker logs -f nodered

# Service status
systemctl status apcupsd
journalctl -u mqtt-volume-control -f

# ZFS
zpool status

# Network
nmcli connection show enp3s0f0
ip addr show enp3s0f0
```

## Related Documentation

- [hsb0 README](../hsb0/README.md) - DNS/DHCP server
- [Repository README](../../docs/README.md) - NixOS configuration guide
- [Runbook](../../docs/RUNBOOK-hsb1.md) - Operational procedures
