# gpc0 - Gaming PC

## Purpose

Primary gaming desktop system with AMD GPU, Steam, Gamescope, and emulation support. Multi-user system shared with Patrizio Bekerle (`omega`).

## Quick Reference

| Item              | Value                                             |
| ----------------- | ------------------------------------------------- |
| **Hostname**      | `gpc0` (formerly `mba-gaming-pc`)                 |
| **Type**          | Desktop Gaming PC                                 |
| **Motherboard**   | MSI MS-7978 v2.0 (Z170 chipset)                   |
| **CPU**           | Intel Core i7-7700K @ 4.20GHz (4C/8T, Kaby Lake)  |
| **RAM**           | 16 GB DDR4                                        |
| **GPU**           | AMD Radeon RX 9070 XT (RDNA 4, 16GB VRAM)         |
| **Storage**       | 3× Samsung SSDs (500GB + 500GB + 4TB = 5TB total) |
| **Filesystem**    | ZFS (mbazroot pool, 49% used)                     |
| **Network**       | DHCP (Gigabit Ethernet `enp9s0`)                  |
| **Static IP**     | `192.168.1.154/24` (DHCP reservation)             |
| **Gateway**       | `192.168.1.5` (Fritz!Box)                         |
| **DNS**           | `192.168.1.99` (hsb0 - AdGuard Home)              |
| **SSH Access**    | `ssh mba@192.168.1.154` or `ssh mba@gpc0.lan`     |
| **ZFS Pool**      | `mbazroot` (464 GB, 230 GB used)                  |
| **ZFS Host ID**   | `96cb2b24`                                        |
| **Users**         | `mba` (Markus Barta), `omega` (Patrizio Bekerle)  |
| **Configuration** | External Hokage pattern (`github:pbek/nixcfg`)    |

## Features

| ID  | Technical               | User-Friendly                                    | Test |
| --- | ----------------------- | ------------------------------------------------ | ---- |
| F00 | NixOS Base System       | Stable system foundation with generation mgmt    | -    |
| F01 | Steam + Gamescope       | PC gaming with HDR and performance optimizations | -    |
| F02 | AMD GPU (amdgpu driver) | Native Linux gaming with Vulkan support          | -    |
| F03 | Ryubing Emulator        | Nintendo Switch emulation (high DPI mode)        | -    |
| F04 | Flatpak                 | Additional app store for games and software      | -    |
| F05 | ZFS Storage             | Reliable storage with compression & snapshots    | -    |
| F06 | Multi-User Support      | Shared system with separate user profiles        | -    |
| F07 | 1Password GUI           | Secure password management                       | -    |
| F08 | VLC + mplayer           | Media playback for trailers and videos           | -    |
| F09 | NixOS Build Host        | Fast builds with 8 threads and 16GB RAM          | -    |

---

## NixOS Build Capabilities

gpc0 is the **most powerful NixOS build machine** in the infrastructure, making it ideal for:

### Build Performance

| Metric            | Value                          | Comparison                  |
| ----------------- | ------------------------------ | --------------------------- |
| **CPU Threads**   | 8 (4C × 2T)                    | 2× more than hsb0/hsb1/hsb8 |
| **CPU Speed**     | 4.20 GHz (4.60 turbo)          | ~2× faster than Mac minis   |
| **RAM**           | 16 GB DDR4                     | Same as hsb1, 2× hsb0/hsb8  |
| **Storage Speed** | SATA SSD (Samsung 840/850/860) | Fast random I/O for /nix    |
| **Architecture**  | x86_64 (native)                | No cross-compilation needed |

### Use Cases

1. **Local NixOS Rebuilds**

   ```bash
   cd ~/Code/nixcfg
   just switch              # Fast local rebuilds (~2-5 min)
   just upgrade             # Flake update + rebuild
   ```

2. **Building for Other Hosts**

   ```bash
   # Build configuration for another host (without deploying)
   nixos-rebuild build --flake .#hsb0
   nixos-rebuild build --flake .#hsb1
   nixos-rebuild build --flake .#hsb8
   ```

3. **Remote Deployment** (push to other machines)

   ```bash
   # Deploy to home servers from gpc0
   nixos-rebuild switch --flake .#hsb0 --target-host mba@192.168.1.99
   nixos-rebuild switch --flake .#hsb1 --target-host mba@192.168.1.101
   ```

4. **Testing in VM**

   ```bash
   # Build and boot VM for testing
   nixos-rebuild --flake .#gpc0 build-vm
   just boot-vm-no-kvm
   ```

5. **Nix Package Development**

   ```bash
   # Build local packages
   nix build .#qownnotes
   nix build .#nixbit

   # Enter development shell
   nix develop
   ```

### Build Time Comparison

| Host     | CPU                | Threads | Typical Rebuild  |
| -------- | ------------------ | ------- | ---------------- |
| **gpc0** | i7-7700K @ 4.20GHz | 8       | **~2-5 min** ⚡  |
| hsb1     | i7-4578U @ 3.00GHz | 4       | ~5-10 min        |
| hsb0     | i5-2415M @ 2.30GHz | 4       | ~8-15 min        |
| hsb8     | i5-2415M @ 2.30GHz | 4       | ~8-15 min        |
| imac0    | Apple M1 (Rosetta) | 8       | Varies (HM only) |

**gpc0 is recommended** for building complex configurations or when iterating quickly on changes.

---

## Installation

### Prerequisites

- ✅ **Boot Media**: USB stick with NixOS minimal ISO (nixos-minimal-25.05 or later)
- ✅ **BIOS Settings**: Boot from USB enabled
- ✅ **Network**: Connected to local network (192.168.1.x)

### Fresh Installation with nixos-anywhere

**From another NixOS machine (e.g., hsb1):**

```bash
# SSH into build machine
ssh mba@192.168.1.101

# Navigate to repository
cd ~/Code/nixcfg

# Deploy to gpc0 (replace IP with actual DHCP IP from boot)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#gpc0 \
  root@<DHCP_IP>
```

**From gpc0 after booting NixOS ISO:**

```bash
# Set root password for SSH
sudo passwd

# Get IP address
ip addr show

# Note the IP for nixos-anywhere deployment
```

### Post-Installation

```bash
# SSH into new system
ssh mba@192.168.1.154

# Clone repository
mkdir -p ~/Code
cd ~/Code
git clone https://github.com/markus-barta/nixcfg.git

# Verify system
hostnamectl
zpool status
```

### Reinstallation (Preserving Windows)

The current disk layout preserves the Windows installation on `sda`:

```text
sda - Windows (DO NOT TOUCH during reinstall)
sdb - NixOS/ZFS (can be reformatted)
sdc - Data storage (optional, can be added to ZFS)
```

To reinstall NixOS while keeping Windows:

1. Boot from USB
2. Run nixos-anywhere targeting only the NixOS disk
3. ZFS pool will be recreated on `sdb`

---

## Configuration Management

### Deploying Changes

```bash
# On gpc0
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
- [Migration Plan](docs/MIGRATION-PLAN-HOKAGE.md) - Migration details from mba-gaming-pc

---

## Hardware Specifications

### System Details

- **Motherboard**: MSI MS-7978 v2.0
  - **Chipset**: Intel Z170
  - **BIOS**: A.D0 (2018-07-04)
  - **Form Factor**: ATX
- **CPU**: Intel Core i7-7700K @ 4.20GHz
  - **Cores/Threads**: 4 cores, 8 threads (2 threads per core)
  - **Architecture**: Kaby Lake (7th generation)
  - **Base Clock**: 4.20 GHz
  - **Max Turbo**: 4.60 GHz
  - **Cache**: L1d 128 KiB, L1i 128 KiB, L2 1 MiB, L3 8 MiB
  - **Virtualization**: VT-x enabled (`kvm-intel` module)
  - **Features**: AVX2, AES-NI, Intel HWP
- **RAM**: 16 GB DDR4
  - **Usable**: 15 GiB
  - **Swap**: 7.8 GB (zram compressed)
- **GPU**: AMD Radeon RX 9070 XT
  - **Architecture**: RDNA 4 (GFX12)
  - **ASIC**: GFX1201
  - **VRAM**: 16 GB GDDR6
  - **Driver**: `amdgpu` (open-source, DRM 3.64.0)
  - **PCI**: `0000:03:00.0`
  - **Device ID**: `1002:7550`
  - **Monitoring**: `amdgpu_top` v0.11.0, `lact`
  - **Outputs**: 3× DisplayPort, 1× HDMI
- **Network**: Gigabit Ethernet (`enp9s0`)

### Storage Configuration

| Device | Model                     | Size   | Interface | Purpose          |
| ------ | ------------------------- | ------ | --------- | ---------------- |
| `sda`  | Samsung SSD 850 EVO 500GB | 466 GB | SATA      | Windows (legacy) |
| `sdb`  | Samsung SSD 840 EVO 500GB | 466 GB | SATA      | NixOS (ZFS boot) |
| `sdc`  | Samsung SSD 860 QVO 4TB   | 3.6 TB | SATA      | Data storage     |

**Total Storage**: ~5 TB (all SSD, no spinning disks)

### Software

- **OS**: NixOS 25.11 (Xantusia)
- **Kernel**: Linux 6.17.8
- **Configuration**: External Hokage pattern
- **Theme**: Tokyo Night (Catppuccin disabled)
- **Architecture**: x86_64 GNU/Linux
- **Machine ID**: `a3a897aea664451f992c696e7b5c8992`

### Disk Layout

```text
NAME     SIZE    TYPE  MOUNTPOINT  MODEL
sda      465.8G  disk              Samsung SSD 850 EVO 500GB
├─sda1   450M    part              (Windows EFI)
├─sda2   99M     part              (Windows Recovery)
├─sda3   16M     part              (MSR)
├─sda4   463.8G  part              (Windows C:)
├─sda5   541M    part              (Recovery)
└─sda6   874M    part              (Recovery)

sdb      465.8G  disk              Samsung SSD 840 EVO 500GB
├─sdb1   1M      part              (BIOS boot)
├─sdb2   800M    part  /boot       (ESP, VFAT)
└─sdb3   465G    part              (ZFS mbazroot)

sdc      3.6T    disk              Samsung SSD 860 QVO 4TB
├─sdc1   16M     part              (MSR)
└─sdc2   3.6T    part              (NTFS data partition)

zram0    7.8G    disk  [SWAP]      (compressed swap)
```

### ZFS Configuration

```text
Pool: mbazroot
State: ONLINE (healthy)
Size: 464 GB total
Allocated: 230 GB (49% used)
Free: 234 GB available
Fragmentation: 17%
Compression: zstd (enabled)
Dedup: 1.00x (disabled)
Disk: wwn-0x50025388a0825254-part3 (sdb3)
Last Scrub: Nov 1, 2025 - 0 errors

Datasets:
- mbazroot/root   → /                        (system root)
- mbazroot/home   → /home                    (user data)
- mbazroot/nix    → /nix                     (Nix store)
- mbazroot/docker → /var/lib/docker/volumes  (Docker volumes)

Initial Snapshot: mbazroot@blank
Auto-snapshot: disabled
```

### Performance Comparison (vs Home Servers)

| Feature           | gpc0 (Gaming PC)         | hsb1 (Home Server)      | hsb0 (DNS Server)      |
| ----------------- | ------------------------ | ----------------------- | ---------------------- |
| **CPU**           | i7-7700K @ 4.20GHz       | i7-4578U @ 3.00GHz      | i5-2415M @ 2.30GHz     |
| **Generation**    | 7th gen (Kaby Lake)      | 4th gen (Haswell)       | 2nd gen (Sandy Bridge) |
| **Cores/Threads** | 4C/8T                    | 2C/4T                   | 2C/4T                  |
| **RAM**           | 16 GB DDR4               | 16 GB DDR3              | 8 GB DDR3              |
| **GPU**           | RX 9070 XT (16GB RDNA 4) | Intel Iris (integrated) | Intel HD (integrated)  |
| **Storage**       | 5 TB SSD (3 drives)      | 512 GB Apple SSD        | 250 GB Samsung SSD     |
| **Role**          | Gaming Desktop           | Home Automation         | DNS/DHCP Server        |

**gpc0 is the most powerful system** in the infrastructure, purpose-built for gaming with high-end RDNA 4 graphics.

---

## Gaming Features

### Steam + Gamescope

- **Steam**: Full Proton support for Windows games
- **Gamescope Session**: Dedicated gaming session with:
  - `capSysNice = true` for priority scheduling
  - HDR support (RDNA 4 hardware capability)
  - Variable refresh rate (VRR/FreeSync)
  - Optimized compositor for low latency

### AMD Radeon RX 9070 XT Configuration

| Specification    | Value                    |
| ---------------- | ------------------------ |
| **Architecture** | RDNA 4 (GFX12)           |
| **VRAM**         | 16 GB GDDR6              |
| **Driver**       | `amdgpu` (kernel module) |
| **DRM Version**  | 3.64.0                   |
| **Ray Tracing**  | Hardware RT (2nd gen)    |
| **Video Encode** | AV1, HEVC, H.264         |
| **Video Decode** | AV1, HEVC, H.264, VP9    |

**Monitoring Tools**:

```bash
# Real-time GPU monitoring (CLI)
amdgpu_top

# GPU control and fan curves (GUI)
lact
```

**Kernel Module**: `amdgpu` loaded at boot via `boot.initrd.kernelModules`

### Emulation

- **Ryubing**: Nintendo Switch emulation
  - High DPI mode enabled (`ryubing.highDpi = true`)
  - Vulkan rendering (optimal for RDNA 4)

### Flatpak

Flatpak is enabled for additional gaming software:

```bash
# Search for games
flatpak search <game>

# Install from Flathub
flatpak install flathub <app-id>
```

---

## User Configuration

### Users

| Username | Full Name        | Description                  |
| -------- | ---------------- | ---------------------------- |
| `mba`    | Markus Barta     | Primary user, SSH enabled    |
| `omega`  | Patrizio Bekerle | Secondary user, local access |

### SSH Access

**Authorized keys for `mba`:**

- Primary RSA key (Markus)
- ED25519 key from hsb1 (Node-RED automation)

**SSH to gpc0:**

```bash
# From local network
ssh mba@192.168.1.154
ssh mba@gpc0.lan
```

### Security

- **Passwordless sudo**: Enabled for wheel group (local gaming PC, low risk)
- **Network**: Local only, not exposed to internet

---

## Installed Applications

### System Packages

| Package          | Purpose                     |
| ---------------- | --------------------------- |
| `amdgpu_top`     | AMD GPU monitoring (CLI)    |
| `lact`           | AMD GPU control GUI         |
| `_1password-gui` | Password manager            |
| `vlc`            | Media player                |
| `mplayer`        | Lightweight media player    |
| `brave`          | Privacy-focused web browser |

### Gaming (via Hokage)

- Steam with Proton
- Gamescope compositor
- Ryubing (Switch emulator)
- Various gaming utilities

---

## Hokage Configuration

gpc0 uses the **External Hokage Consumer Pattern** from `github:pbek/nixcfg`:

```nix
hokage = {
  users = [ "mba" "omega" ];
  hostName = "gpc0";
  userLogin = "mba";
  userNameLong = "Markus Barta";
  useInternalInfrastructure = false;
  useSecrets = false;
  useSharedKey = false;

  # Gaming features
  gaming = {
    enable = true;
    ryubing.highDpi = true;
  };

  # ZFS configuration
  zfs = {
    enable = true;
    hostId = "96cb2b24";
    poolName = "mbazroot";
  };

  # Theming
  catppuccin.enable = false;  # Uses Tokyo Night

  # Custom nixbit repository
  programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
};
```

### Disabled Features

- `espanso`: Text expansion (not needed for gaming)
- `git.enableUrlRewriting`: SSH URL rewriting
- `catppuccin`: Using Tokyo Night theme instead

### Excluded Packages

- `onlyoffice-desktopeditors`: Heavy office suite
- `brave`: Installed separately with specific config

---

## Console Configuration

### Large Console Font

For better visibility on high-resolution displays:

- **TTY Font**: Terminus 20pt (`ter-u20n`)
- **kmscon Font Size**: 26pt

---

## Relationship with Other Hosts

### Network Dependencies

- **DNS**: Uses hsb0 (192.168.1.99) via AdGuard Home
- **DHCP**: Static lease assigned by hsb0
- **Ad-blocking**: Network-wide filtering via AdGuard Home

### Configuration Source

- **Hokage**: External from `github:pbek/nixcfg`
- **Uzumaki**: Local `modules/uzumaki/desktop.nix`

---

## Useful Commands

```bash
# GPU monitoring
amdgpu_top                    # Real-time GPU stats
lact                          # GUI for fan curves, power limits
cat /sys/class/drm/card1/device/power_dpm_force_performance_level

# Gaming
steam                         # Launch Steam
gamescope --help              # Gamescope options
gamescope -W 2560 -H 1440 -f  # Example: 1440p fullscreen

# ZFS
zpool status mbazroot         # Pool health
zpool list                    # Pool usage
zfs list                      # Dataset sizes
zpool scrub mbazroot          # Start scrub

# System
hostnamectl                   # System info
nixos-version                 # NixOS version
lscpu                         # CPU details
free -h                       # Memory usage
sensors                       # Temperature sensors

# Flatpak
flatpak list                  # Installed apps
flatpak update                # Update all
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Network
ip addr show enp9s0           # Network interface
ping -c 3 hsb0.lan            # Test DNS resolution
```

---

## Related Documentation

### In This Repository

- [Repository README](../../docs/README.md) - NixOS configuration guide
- [How It Works](../../docs/how-it-works.md) - Architecture and machine inventory
- [Hokage Options](../../docs/hokage-options.md) - Configuration options reference

### Configuration Files

- [configuration.nix](./configuration.nix) - Main system configuration
- [hardware-configuration.nix](./hardware-configuration.nix) - Hardware-specific settings
- [disk-config.zfs.nix](./disk-config.zfs.nix) - ZFS disk layout

### Related Hosts

- [hsb0 README](../hsb0/README.md) - DNS/DHCP server
- [hsb1 README](../hsb1/README.md) - Home automation server
- [hsb8 README](../hsb8/README.md) - Parents' home server
- [Migration Plan](docs/MIGRATION-PLAN-HOKAGE.md) - Hokage migration details

---

## Changelog

### 2025-11-30: Documentation Created

- ✅ Created comprehensive README with detailed hardware specs
- ✅ Added NixOS build capabilities section
- ✅ Added installation instructions
- ✅ Documented all hardware (CPU, GPU, storage, motherboard)
- ✅ Added gaming features documentation
- ✅ Added performance comparison with other hosts

### 2025-11-29: External Hokage Migration

- ✅ Migrated from local hokage to external consumer pattern
- ✅ Renamed hostname from `mba-gaming-pc` to `gpc0`
- ✅ Updated flake.nix to use `github:pbek/nixcfg`
- ✅ Added nixbit repository override
- ✅ Configured Tokyo Night theming (catppuccin disabled)

**See**: [Migration Plan](docs/MIGRATION-PLAN-HOKAGE.md) for details

---

**Last Updated**: November 30, 2025  
**Maintainer**: Markus Barta  
**Repository**: <https://github.com/markus-barta/nixcfg>
