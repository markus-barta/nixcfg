# hsb2 - Raspberry Pi Zero W

## Purpose

Home Server Barta 2 - Lightweight Raspberry Pi server for future home automation tasks.
**Status: Running Raspbian 11 (bullseye) - NixOS migration abandoned due to ARMv6l complexity.**

## Quick Reference

| Item             | Value                                                     |
| ---------------- | --------------------------------------------------------- |
| **Hostname**     | `hsb2`                                                    |
| **Model**        | Raspberry Pi Zero W Rev 1.1                               |
| **CPU**          | ARMv6Z (BCM2835) @ 1GHz (single core)                     |
| **RAM**          | 512 MB                                                    |
| **Storage**      | SD Card (ext4)                                            |
| **Filesystem**   | ext4 (no ZFS - insufficient RAM)                          |
| **Static IP**    | `192.168.1.95/24`                                         |
| **Tailscale IP** | `100.64.0.5` (hsb2.ts.barta.cm)                           |
| **Gateway**      | `192.168.1.5` (Fritz!Box)                                 |
| **SSH Access**   | `ssh hsb2` (auto LAN→Tailscale) or `ssh mba@192.168.1.95` |
| **User**         | `mba` (Markus Barta)                                      |
| **Role**         | `server-home`                                             |
| **Exposure**     | LAN + Tailscale VPN                                       |

## Features

| ID  | Technical         | User-Friendly                  | Test |
| --- | ----------------- | ------------------------------ | ---- |
| F00 | Raspbian OS       | Debian-based stable system     | T00  |
| F01 | SSH Remote Access | Secure remote management       | T01  |
| F02 | WiFi Support      | Built-in wireless connectivity | T02  |
| F03 | Tailscale VPN     | Remote access from anywhere    | T03  |

## Firewall Ports

- **TCP 22**: SSH

---

## Hardware Specifications

### System Details

- **Model**: Raspberry Pi Zero W Rev 1.1
- **CPU**: ARMv6Z (BCM2835) @ 1GHz
  - Single core
  - 32-bit architecture (armv6l)
- **RAM**: 512 MB
- **Storage**: Micro SD Card
- **Network**: Built-in WiFi (802.11 b/g/n)

### Software

- **OS**: Raspbian 11 (bullseye) - staying on Raspbian
- **Architecture**: armv6l-linux (32-bit)
- **NixOS Status**: Migration abandoned - ARMv6l support too complex for Pi Zero W

---

## Installation (Historical - Raspbian Only)

> **Note**: NixOS installation abandoned. This section kept for reference only.

### Current Setup

- **OS**: Raspbian 11 (bullseye) - flashed via Raspberry Pi Imager
- **SSH**: Pre-configured with `mba` user
- **WiFi**: Configured via `wpa_supplicant.conf` on boot partition

### Raspbian Management

Standard Debian/Raspbian administration:

```bash
ssh mba@192.168.1.95

# Update packages
sudo apt update && sudo apt upgrade -y

# Install packages
sudo apt install <package>

# Check system status
systemctl status
free -h
df -h
```

### Historical: NixOS Installation (Abandoned)

The following NixOS installation options were evaluated but abandoned:

#### Option 1: nixos-anywhere

```bash
# Would have deployed via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- \
  --flake .#hsb2 \
  --target-host root@192.168.1.95
```

**Why abandoned**: ARMv6l kexec support unreliable on Pi Zero W.

#### Option 2: SD Card Image

```bash
# Would have built NixOS SD image
nix build .#nixosConfigurations.hsb2.config.system.build.sdImage
```

**Why abandoned**: Complex cross-compilation, limited ARMv6l support.

---

## NixOS Migration Status

**Current Status**: ❌ Abandoned

NixOS migration for Pi Zero W (ARMv6l) abandoned due to:

- Limited NixOS ARMv6l support
- Complex SD card image building requirements
- Low ROI for 512MB RAM device

**Decision**: Keep Raspbian, manage manually.

---

## Architecture

### Design Principles

- **Minimal resource usage**: Optimized for 512MB RAM
- **Headless**: No GUI, SSH only
- **WiFi primary**: No ethernet on Pi Zero W
- **Manual management**: Raspbian (not NixOS)

### Included

- Raspbian base system
- SSH remote access
- WiFi support
- Standard Debian tools (apt, systemd)

### Excluded

- NixOS (migration abandoned)
- ZFS (insufficient RAM)
- Docker (too heavy for 512MB RAM)
- Graphical environment
- Audio subsystem

---

## Changelog

### 2026-01-31: NixOS Migration Abandoned

- **Decision**: Keep Raspbian, abandon NixOS migration
- **Reason**: ARMv6l support too complex for Pi Zero W
- **Actions**:
  - Updated README.md to reflect Raspbian-only status
  - Rewrote RUNBOOK.md with Raspbian/Debian commands
  - Commented out hsb2 from flake.nix
  - Marked all NixOS config files as archived/inactive
- **Current State**: Running Raspbian 11 (bullseye), managed manually

### 2026-01-31: Initial Configuration Created

- Created host directory structure
- Added to flake.nix
- Added host key to secrets.nix
- Created base configuration for armv6l

---

## Additional Resources

- **Raspberry Pi Zero W Specs**: https://www.raspberrypi.com/products/raspberry-pi-zero-w/
- **NixOS on Raspberry Pi**: https://nixos.wiki/wiki/NixOS_on_ARM/Raspberry_Pi
- **NixOS Manual**: https://nixos.org/manual/nixos/stable/
