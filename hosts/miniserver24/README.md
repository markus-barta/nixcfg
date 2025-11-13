# miniserver24 - Home Automation Server

## Purpose

Home automation hub running HomeAssistant, Node-RED, Scrypted, and related services.

## Quick Reference

- **IP Address**: `192.168.1.101/24`
- **Gateway**: `192.168.1.5` (Fritz!Box)
- **DNS**: `192.168.1.99` (miniserver99/AdGuard Home) + `1.1.1.1` (fallback)
- **Web Interfaces**:
  - Node-RED: http://192.168.1.101:1880
  - Zigbee2MQTT: http://192.168.1.101:8888
  - Apprise: http://192.168.1.101:8001
- **SSH**: `ssh mba@192.168.1.101`

## System Details

- **Hardware**: Mac mini (Intel)
- **ZFS hostId**: `dabfdb01`
- **User**: `mba` (Markus Barta)
- **Role**: `server-home` (via `serverMba.enable`)
- **Network Interface**: `enp3s0f0`

## Network Configuration

### DNS Resolution
- **Primary DNS**: miniserver99 (192.168.1.99) running AdGuard Home
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
- Ports would be: 80, 443, 1880, 1883, 5223, 5353, 9000, 51827, 554
- fail2ban also disabled

## Docker Containers

All containers run with host network access and DNS resolution:

| Container | Purpose | Ports |
|-----------|---------|-------|
| **nodered** | Home automation flows | 1880 |
| **homeassistant** | Smart home platform | - |
| **mosquitto** | MQTT broker | 1883, 9001 |
| **zigbee2mqtt** | Zigbee bridge | 8888 |
| **scrypted** | Camera/video platform | - |
| **apprise** | Notifications | 8001 |
| **matter-server** | Matter protocol | - |
| **opus-stream-to-mqtt** | Audio streaming | - |
| **watchtower-weekly** | Auto-updates | - |
| **smtp** | Mail relay | 25 |
| **restic-cron-hetzner** | Backups | - |

## Native Services

- **APC UPS Monitoring**: USB-connected UPS with MQTT status publishing (every 1 min)
- **VLC Kiosk Mode**: Auto-login `kiosk` user for camera viewing (fullscreen)
- **MQTT Volume Control**: Controls VLC volume via MQTT topic `home/miniserver24/kiosk-vlc-volume`
- **ZFS**: Auto-scrubbing enabled
- **FLIRC IR-USB**: Remote control support
- **Bluetooth**: Enabled

## Relationship with miniserver99

miniserver24 depends on miniserver99 for:
- **DNS Resolution**: All DNS queries → AdGuard Home (192.168.1.99)
- **DHCP**: Static lease assigned by miniserver99
- **Ad-blocking**: Network-wide filtering via AdGuard Home

If miniserver99 is down:
- DNS falls back to Cloudflare (1.1.1.1)
- Static IP remains functional
- Ad-blocking unavailable

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

- [miniserver99 README](../miniserver99/README.md) - DNS/DHCP server
- [Repository README](../../docs/README.md) - NixOS configuration guide

