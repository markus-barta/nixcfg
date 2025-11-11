# NixOS Installation Guide for miniserver99

## Overview

This guide walks through installing NixOS on an old Mac mini using **Ventoy** (optional) and **nixos-anywhere** for remote deployment.

## Prerequisites

- ✅ **Boot Media**: Choose one of the following:
  - **Option A (Recommended)**: Ventoy USB Stick with NixOS minimal ISO
    - Image: `nixos-minimal-25.05.804936.a676066377a2-x86_64-linux.iso`
    - Ventoy allows booting multiple ISO images from a single USB stick
    - No need to rewrite the USB for different images!
  - **Option B (Current)**: USB Stick with NixOS minimal ISO installed directly
    - Image: `nixos-minimal-25.05.804936.a676066377a2-x86_64-linux.iso`
    - Use `dd` or similar tool to write ISO directly to USB
- ✅ **Target Machine**: Mac mini (miniserver99)
- ✅ **Source Machine**: 
  - **Recommended**: miniserver24 (192.168.1.101) - Can build overnight, already NixOS
  - **Alternative**: Your Mac with this repository cloned at `~/Code/nixcfg`
- ✅ **Network**: All machines on the same network (192.168.1.x)

## Why Install from miniserver24?

**Advantages of using miniserver24 as the source machine:**

1. ✅ **Native NixOS** - Can build x86_64-linux packages without cross-compilation
2. ✅ **Run overnight** - Long builds won't block your Mac
3. ✅ **Server reliability** - Stays online, no laptop sleep/lid closing
4. ✅ **Faster builds** - Direct Linux-to-Linux deployment
5. ✅ **Same network** - Both servers on 192.168.1.x subnet

**Instructions in this guide work from both miniserver24 and your Mac.** Just adjust paths accordingly.

## Boot Media Options

### Option A: Ventoy (Recommended)

[Ventoy](https://www.ventoy.net/) is a bootable USB solution that allows you to:

- Copy ISO files directly to the USB stick (no burning/flashing)
- Boot multiple operating systems from one USB stick
- No need to reformat the USB when changing ISOs
- Works with UEFI and Legacy BIOS

**Your Ventoy USB contains:**

```bash
/Volumes/Ventoy/
└── nixos-minimal-25.05.804936.a676066377a2-x86_64-linux.iso (1.5GB)
```

### Option B: Direct ISO Installation (Current)

For simpler setups, you can write the NixOS minimal ISO directly to a USB stick:

```bash
# On macOS/Linux
sudo dd if=nixos-minimal-25.05.804936.a676066377a2-x86_64-linux.iso of=/dev/sdX bs=4M

# Replace /dev/sdX with your USB device (be careful!)
```

## What is nixos-anywhere?

[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) is a tool that:

- Installs NixOS on a remote machine over SSH
- Automatically partitions disks using disko
- Deploys your flake configuration
- Works from any machine (doesn't need to be NixOS)

## Installation Steps

### 1. Boot the Mac mini from USB

**For Ventoy (Option A):**
1. **Insert the Ventoy USB stick** into the Mac mini
2. **Power on** the Mac mini while holding the **⌥ Option (Alt)** key
3. **Select the Ventoy USB** from the boot menu (usually labeled "EFI Boot")
4. **In Ventoy menu**, select:
   ```
   nixos-minimal-25.05.804936.a676066377a2-x86_64-linux.iso
   ```
5. Wait for NixOS minimal environment to boot (headless - no GUI)

**For Direct ISO (Option B):**
1. **Insert the USB stick** with NixOS minimal ISO into the Mac mini
2. **Power on** the Mac mini while holding the **⌥ Option (Alt)** key
3. **Select the USB stick** from the boot menu (usually labeled "EFI Boot")
4. The ISO will boot directly into the NixOS minimal environment (headless - no GUI)

### 2. Configure the NixOS Minimal Environment

Once booted into the minimal NixOS environment:

```bash
# Set a root password (you'll need this for SSH)
sudo passwd

# Check the network interface name
ip link show
# Expected: enp2s0f0 or similar (update configuration.nix if different)

# Get the IP address assigned by DHCP
ip addr show
# Note this IP - you'll need it for nixos-anywhere
# Example: 192.168.1.XXX

# Verify network connectivity
ping 1.1.1.1
```

SSH is already enabled in this ISO with password authentication and root login permitted by default. After setting the root password, you can connect immediately over SSH.

Note: If your ISO differs and SSH is not running, start it with:

```bash
sudo systemctl start sshd
```

### 3. Prepare Source Machine (miniserver24 or Mac)

**Option A: From miniserver24 (RECOMMENDED):**

```bash
# SSH into miniserver24
ssh mba@192.168.1.101

# Navigate to repository (or clone if needed)
cd ~/Code/nixcfg
# git pull  # If already cloned

# Ensure static-leases.nix exists
ls -la hosts/miniserver99/static-leases.nix

# Verify miniserver99 configuration
nix flake show | grep miniserver99
```

**Option B: From your Mac:**

```bash
# Navigate to the repository
cd ~/Code/nixcfg

# Verify miniserver99 configuration exists
ls -la hosts/miniserver99/

# Test the configuration build locally first
nix flake check

# Build miniserver99 configuration (optional but recommended)
nixos-rebuild build --flake .#miniserver99
```

### 4. Deploy with nixos-anywhere

**Important:** The Mac mini's IP from step 2 (let's say it's `192.168.1.150` for this example).

**From miniserver24 (or your Mac):**

```bash
# Run nixos-anywhere
# Replace 192.168.1.150 with the actual IP from step 2
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@192.168.1.150

# You'll be prompted for the root password you set in step 2
```

**If running from miniserver24, you can detach and let it run:**

```bash
# Optional: Run in tmux for long builds
tmux new -s miniserver99-install
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@192.168.1.150

# Detach with Ctrl+B, then D
# Reattach later with: tmux attach -t miniserver99-install
```

**What happens:**

1. nixos-anywhere connects via SSH to the Mac mini
2. Partitions the disk using `hosts/miniserver99/disk-config.zfs.nix`
3. Creates ZFS pool with hostId `dabfdb02`
4. Installs NixOS using the miniserver99 flake configuration
5. Sets up bootloader for Mac EFI
6. Reboots the machine

### 5. First Boot

After installation completes:

1. **Remove the Ventoy USB stick**
2. **Reboot** the Mac mini
3. Machine should boot into NixOS at **192.168.1.99**
4. Wait ~30 seconds for boot and network configuration

### 6. Verify Installation

From miniserver24 or your Mac:

```bash
# SSH into the new system (use your SSH key)
ssh mba@192.168.1.99

# Check system status
systemctl status

# Verify AdGuard Home is running
systemctl status adguardhome
journalctl -u adguardhome -f

# Check ZFS pool
zpool status

# Verify network configuration
ip addr show enp2s0f0
# Should show: 192.168.1.99/24

# Test DNS
dig @localhost google.com

# Check DHCP status (should be DISABLED initially)
systemctl status adguardhome | grep -i dhcp

# Access AdGuard Home web interface from your browser:
# http://192.168.1.99:3000
```

⚠️ **IMPORTANT:** DHCP is **DISABLED by default** to prevent conflicts with miniserver24!

### 7. Enable DHCP Server (After Disabling miniserver24)

**⚠️ CRITICAL: Do NOT enable DHCP on miniserver99 until miniserver24 DHCP is stopped!**

**Step-by-Step DHCP Cutover:**

1. **Test DNS first** (DHCP still on miniserver24):

   ```bash
   # From any client, test miniserver99 DNS
   dig @192.168.1.99 google.com
   
   # Should return results
   ```

2. **Disable PiHole DHCP on miniserver24:**

   ```bash
   # SSH to miniserver24
   ssh mba@192.168.1.101
   
   # Stop PiHole DHCP (via Docker)
   sudo docker exec pihole pihole-FTL dhcp-discover
   
   # Or disable via web interface:
   # http://192.168.1.101/admin → Settings → DHCP → Disable
   ```

3. **Enable DHCP on miniserver99:**

   ```bash
   # On miniserver24 (where repo is cloned) or your Mac
   cd ~/Code/nixcfg
   
   # Edit configuration
   nano hosts/miniserver99/configuration.nix
   
   # Change line ~31 from:
   #   enableDhcp = false;
   # To:
   #   enableDhcp = true;
   
   # Commit and push
   git add hosts/miniserver99/configuration.nix
   git commit -m "Enable DHCP on miniserver99"
   git push
   ```

4. **Deploy the change:**

   ```bash
   # SSH to miniserver99
   ssh mba@192.168.1.99
   
   # Pull changes
   cd ~/Code/nixcfg
   git pull
   
   # Apply configuration
   sudo nixos-rebuild switch --flake .#miniserver99
   
   # Verify DHCP is now enabled
   systemctl status adguardhome | grep -i dhcp
   # Should show "DHCP: enabled"
   
   # Check logs
   journalctl -u adguardhome -f
   ```

5. **Test DHCP:**

   ```bash
   # Renew lease on a test client
   # Linux:
   sudo dhclient -r enp0s3 && sudo dhclient enp0s3
   
   # macOS:
   sudo ipconfig set en0 DHCP
   
   # Windows (as Administrator):
   ipconfig /release
   ipconfig /renew
   
   # Verify new lease from AdGuard Home
   # Check web interface: http://192.168.1.99:3000
   # Settings → DHCP settings → Leases
   ```

6. **Monitor for 24 hours** before decommissioning miniserver24 PiHole

### 8. Post-Installation Configuration

```bash
# On miniserver99 via SSH

# Update the hardware configuration (generated on actual hardware)
sudo nixos-generate-config --show-hardware-config > /tmp/hardware-config.nix
# Copy this back to hosts/miniserver99/hardware-configuration.nix on your Mac

# If network interface name differs from enp3s0f0:
# Update hosts/miniserver99/configuration.nix accordingly

# Apply any configuration changes from your Mac:
# Edit files, commit, push to Git, then:
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#miniserver99
```

## Troubleshooting

### Can't Boot from USB

- Try holding ⌥ Option key longer during startup
- Check UEFI/BIOS settings (if accessible) to enable USB boot
- Try different USB port
- **For direct ISO**: Verify the ISO was written correctly (compare checksums)

### SSH Connection Refused

```bash
# From the Mac mini console (keyboard/monitor if available):
systemctl status sshd
systemctl start sshd

# Check firewall
iptables -L

# Verify IP address
ip addr show
```

### Wrong Network Interface Name

If the network interface is not `enp2s0f0`:

1. Boot into NixOS minimal again
2. Check actual interface name: `ip link show`
3. Update `hosts/miniserver99/configuration.nix`:
   ```nix
   interfaces.YOUR_INTERFACE_NAME = {
     ipv4.addresses = [ ... ];
   };
   ```
4. Re-run nixos-anywhere

### Disk Partitioning Fails

Check if disk is `/dev/sda` or different:

```bash
# On Mac mini
lsblk
fdisk -l

# Update hosts/miniserver99/disk-config.zfs.nix if needed
```

### nixos-anywhere Fails Midway

Safe to re-run - it will repartition and start fresh:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@192.168.1.150
```

### Need to Fix Bootloader Later

If UEFI gets corrupted or reset:

```bash
# Boot from Ventoy USB (Option A) or USB with direct ISO (Option B) again
# Mount the installed system
sudo su -
mount /dev/mapper/YOUR_ZFS_POOL /mnt
mount /dev/sda1 /mnt/boot  # or your EFI partition

# Reinstall bootloader
cd /mnt/home/mba/Code/nixcfg
nixos-install --flake .#miniserver99

reboot
```

## Static DHCP Leases Setup

The static DHCP leases (`static-leases.nix`) need to be present before deployment:

### Option 1: Deploy Without Static Leases First

1. Temporarily comment out the static leases import in `configuration.nix`:
   ```nix
   # static_leases = staticLeases.static_leases;
   static_leases = [];
   ```
2. Deploy with nixos-anywhere
3. After successful deployment, restore `static-leases.nix` and rebuild

### Option 2: Deploy With Static Leases

1. Ensure `hosts/miniserver99/static-leases.nix` exists on your Mac
2. nixos-anywhere will copy it during deployment
3. AdGuard Home will have all 115 static leases configured on first boot

## Next Steps

After successful installation, see:

- **[miniserver99 README.md](../../hosts/miniserver99/README.md)** - Service configuration and management
- **[Migration Guide](../../hosts/miniserver99/README.md#migration-from-miniserver24-pihole)** - Migrating from miniserver24 PiHole

## Quick Reference

**Boot Mac mini from USB:**

```
Power On + Hold ⌥ Option → Select Ventoy → Select NixOS ISO
```

**Deploy Command (from miniserver24 or Mac):**

```bash
# Recommended: From miniserver24
ssh mba@192.168.1.101
cd ~/Code/nixcfg
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@<MAC_MINI_IP>
```

**Access After Install:**

```bash
ssh mba@192.168.1.99
http://192.168.1.99:3000  # AdGuard Home
```

## Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Boot USB** | Ventoy (optional) 🚀 | Multi-ISO bootable USB (no flashing needed) |
| **ISO Image** | NixOS Minimal 25.05 | Lightweight installer environment |
| **Deployment** | nixos-anywhere | Remote installation over SSH |
| **Disk Management** | disko | Declarative disk partitioning |
| **Filesystem** | ZFS | Advanced filesystem with snapshots |
| **Configuration** | NixOS Flakes | Declarative system configuration |
| **Target Hardware** | Mac mini | Old Mac mini (Intel-based) |

---

**Good luck with your installation! 🎉**

