# hsb2 - Raspberry Pi Zero W

## Purpose

Home Server Barta 2 - Lightweight Raspberry Pi server for future home automation tasks.
Currently running Raspbian, planned migration to NixOS.

## Quick Reference

| Item           | Value                                 |
| -------------- | ------------------------------------- |
| **Hostname**   | `hsb2` (currently `raspi01`)          |
| **Model**      | Raspberry Pi Zero W Rev 1.1           |
| **CPU**        | ARMv6Z (BCM2835) @ 1GHz (single core) |
| **RAM**        | 512 MB                                |
| **Storage**    | SD Card (ext4)                        |
| **Filesystem** | ext4 (no ZFS - insufficient RAM)      |
| **Static IP**  | `192.168.1.95/24`                     |
| **Gateway**    | `192.168.1.5` (Fritz!Box)             |
| **SSH Access** | `ssh mba@192.168.1.95`                |
| **User**       | `mba` (Markus Barta)                  |
| **Role**       | `server-home`                         |
| **Exposure**   | LAN-only (192.168.1.0/24)             |

## Features

| ID  | Technical         | User-Friendly                  | Test |
| --- | ----------------- | ------------------------------ | ---- |
| F00 | NixOS Base System | Stable system foundation       | T00  |
| F01 | SSH Remote Access | Secure remote management       | T01  |
| F02 | WiFi Support      | Built-in wireless connectivity | T02  |

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

- **OS**: Planned NixOS (currently Raspbian 11 bullseye)
- **Architecture**: armv6l-linux (32-bit)

---

## Installation

### Prerequisites

- Raspberry Pi Zero W with SD card
- Access to home network
- SSH access to raspi01 at 192.168.1.95

### Installation Options

#### Option 1: nixos-anywhere (Recommended for Remote Deploy)

Deploy NixOS directly over SSH without manual SD card flashing.

**Requirements:**

- Root access via SSH to current system (raspi01)
- kexec-tools may need to be installed on target first

**From your Mac or gpc0:**

```bash
cd ~/Code/nixcfg

# Deploy via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- \
  --flake .#hsb2 \
  --target-host root@192.168.1.95
```

**⚠️ Pi Zero W Limitations:**

- ARMv6l architecture has limited nixos-anywhere support
- kexec may not work on older Pi kernels
- If nixos-anywhere fails, use Option 2 (SD card image)

#### Option 2: SD Card Image (Most Reliable)

Build a NixOS SD card image and flash it manually.

```bash
# Build SD card image (run on Linux/x86_64 with QEMU)
nix build .#nixosConfigurations.hsb2.config.system.build.sdImage

# Flash to SD card
dd if=result/sd-image/nixos-sd-image-*.img of=/dev/sdX bs=4M status=progress
```

**Post-flash steps:**

1. Insert SD card into Pi Zero W
2. Boot and wait for WiFi connection
3. SSH in: `ssh mba@192.168.1.95`
4. Generate hardware config: `nixos-generate-config --show-hardware-config`
5. Copy hardware-config.nix back to this repo
6. Deploy full config: `just switch`

---

## Migration Status

**Current Status**: 🔧 Planned

- [ ] Create NixOS configuration
- [ ] Prepare SD card image
- [ ] Test WiFi connectivity
- [ ] Deploy and verify
- [ ] Add to NixFleet

---

## Architecture

### Design Principles

- **Minimal resource usage**: Optimized for 512MB RAM
- **No ZFS**: Uses ext4 (ZFS requires 2GB+ RAM)
- **Headless**: No GUI, SSH only
- **WiFi primary**: No ethernet on Pi Zero W

### Included

- SSH remote access
- WiFi support
- Firewall

### Excluded

- ZFS (insufficient RAM)
- Docker (too heavy for 512MB RAM)
- Graphical environment
- Audio subsystem

---

## Changelog

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
