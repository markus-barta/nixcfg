# P1506 - csb0 ZFS Boot Loop Incident (hostid mismatch)

**Created**: 2026-01-18, 13:00 CET
**Priority**: P1506 (Critical)
**Status**: In Progress
**Context**: Following P1505 (Docker Refactor), a reboot of `csb0` triggered a ZFS import loop due to a `hostid` mismatch.

---

## 🚨 The Incident

After changing `hostId` in `configuration.nix` (from `dabfdc01` to `ad684098`) and rebooting, NixOS refused to import the `zroot` pool.
**Error**: `cannot import 'zroot': pool was previously in use from another system. Last accessed by csb0 (hostid=dabfdc01)`.

NixOS Stage 1 dropped into a retry loop, preventing access to the emergency shell.

---

## 🛑 Failed Recovery Attempts

### 1. NixOS Emergency Shell (Stage 1)

- **Method**: Press `*` to interrupt retry loop.
- **Result**: Failed. The loop was too tight or the shell was unresponsive/unstable. `kernel panic` observed after timeouts.

### 2. GRUB Parameters

- **Attempt A**: `zfs_force=1` appended to linux line.
- **Result**: Ignored by initrd or not sufficient to break the specific `hostid` check loop.
- **Attempt B**: `init=/bin/sh`.
- **Result**: Failed. Could not get a stable environment with ZFS tools loaded.

### 3. Netcup Rescue System (Alpine/Grml)

- **Attempt**: Default Netcup "Rescue System".
- **Result**: The default image is an old Grml (Debian-based) that **lacks ZFS kernel modules** by default. `modprobe zfs` failed.

### 4. Official DVDs (ISO Boot)

We cycled through multiple ISOs to find one with ZFS support:

- **SystemRescue CD 12.03**:
  - **Issue**: Boots, but ZFS tools missing from default path.
  - **Fix Attempt**: Boot with `zfs=on`.
  - **Result**: `modprobe zfs` still failed or command not found. (SystemRescue split ZFS into a separate module recently).

- **Ubuntu 24.04 Live Server**:
  - **Issue**: Hung at boot (`Loading Kernel Module efi_pstore` or `loop` module).
  - **Fix Attempt**: Added `nomodeset acpi=off`.
  - **Result**: Progressed further but hung at `loop` module loading (snapd interaction with virtio?).

- **Arch Linux 2025.12**:
  - **Issue**: Booted to shell, but ZFS tools not present (`pacman -Sy zfs-linux` failed as ZFS is not in official repos).

- **Finnix**:
  - **Issue**: Booted, but `apt update` failed due to GPG errors (system clock was in the past).

- **GParted Live**:
  - **Issue**: Can _see_ ZFS partitions but typically lacks `zpool` import/export tools for manipulation.

- **Grml 2025.12 (Custom ISO)**:
  - **Current State**:
    - Booted successfully.
    - `apt update` failed initially (GPG error) -> **Fix**: `date -s ...`.
    - `apt install zfs-linux` failed -> **Fix**: Added `--allow-insecure...` flags.
    - Kernel module missing -> **Current Action**: Installing `zfs-dkms` and `linux-headers` to compile the module on the fly.

---

## 🛠️ The Working Solution (In Progress at 15:05 CET)

**Environment**: Grml Live 2025.12 (Debian Bookworm based).

**Procedure**:

1.  **Fix Clock**: `date -s "2026-01-18 12:30:00"` (Crucial for APT/GPG).
2.  **Enable Contrib/Non-Free**: Added repositories to `sources.list`.
3.  **Install Headers & DKMS**:
    ```bash
    apt update --allow-insecure-repositories --allow-unauthenticated
    apt install linux-headers-amd64 zfs-dkms zfsutils-linux --allow-unauthenticated
    ```
4.  **Load Module**: `modprobe zfs`.
5.  **Reset ZFS Flag**:
    ```bash
    zpool import -f zroot
    zpool export zroot
    reboot
    ```

---

## 📉 Root Cause Analysis

- **Primary**: Changing `networking.hostId` in NixOS without a clean ZFS export/import cycle on the _active_ system caused the mismatch on next boot.
- **Secondary**: Netcup's default rescue environment is outdated/minimal regarding ZFS.
- **Tertiary**: Virtualization incompatibilities (Ubuntu boot hang) and licensing issues (ZFS stripped from standard ISOs) complicated access to a ZFS-capable shell.

## ✅ Lessons Learned

- **Never change `hostId`** on a ZFS system unless absolutely necessary, and if so, do `zpool export` from a live CD _before_ booting the new config.
- **Reliable Rescue**: Need to keep a custom-built NixOS Rescue ISO or a verified "fat" SystemRescue image on the Netcup FTP for future emergencies.
- **Grml + DKMS**: Valid fallback, but slow.
