# hsb8 Server Recovery Instructions

**Date**: 2025-11-22
**Status**: 🚨 SERVER LOCKED OUT - Physical access required

## Situation

After reboot, SSH access to `hsb8` (192.168.1.100) is broken. The `mba` user cannot login remotely.

**Root Cause**: The hokage `server-home.nix` module was auto-injecting external SSH keys (omega@yubikey, omega@rsa, etc.) but NOT your personal SSH key. After migration to explicit hokage configuration, you lost SSH access.

**Fix Status**: ✅ Committed to Git (commit `dc309f0`)

## Recovery Steps

### 1. Physical Access Required

Connect keyboard and monitor to `hsb8` server at `192.168.1.100`.

### 2. Login Locally

Login as `mba` user at the console (use password or whatever local auth you have).

### 3. Pull the Fix

```bash
cd ~/nixcfg
git pull
```

**Expected output**: Should show updates to `hosts/hsb8/configuration.nix` with `lib.mkForce` SSH key override.

### 4. Apply the Configuration

**Simple (recommended)**:

```bash
just s
```

**Or full command**:

```bash
sudo nixos-rebuild switch --flake .#hsb8
```

**What this does**:

- Rebuilds NixOS configuration with explicit SSH keys (mba + gb only)
- Uses `lib.mkForce` to override hokage's default external keys
- Applies changes immediately (no reboot needed)

### 5. Test SSH Access

From your Mac:

```bash
ssh mba@192.168.1.100
```

**Expected**: Should connect successfully with your SSH key.

### 6. Verify No External Keys

On the server:

```bash
cat ~/.ssh/authorized_keys
```

**Expected**: Should show ONLY your SSH key (`ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H...`), NOT omega keys.

## What Was Fixed

**File**: `hosts/hsb8/configuration.nix`

**Changes**:

```nix
# Added explicit SSH key override with lib.mkForce
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H..." # mba@markus
  ];
};

users.users.gb = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71q..." # gb@gerhard
  ];
};
```

**Why `lib.mkForce`**: Completely replaces hokage's key list (omega@\* keys) with your own keys.

## If You Can't Login Locally

If you cannot login at the console (no password, etc.), you'll need to:

1. Boot from NixOS installer USB
2. Chroot into the system
3. Manually edit `/etc/nixos/configuration.nix` or pull from Git
4. Rebuild and reboot

(This is more complex - let me know if you need detailed instructions)

## Going Forward

**For hsb0 and all future servers**: Add the same `lib.mkForce` SSH key override when using external hokage modules. See:

- `hosts/hsb0/SSH-KEY-SECURITY-NOTE.md` - For hsb0 migration plan
- `hosts/hsb8/archive/POST-HOKAGE-MIGRATION-SSH-FIX.md` - Detailed analysis

**Security principle**: External modules (like hokage from `github:pbek/nixcfg`) may inject unwanted configuration. Always audit and explicitly override security-critical settings (SSH keys, firewall, secrets) with `lib.mkForce`.

## Questions?

If you encounter any issues during recovery, the rollback is simple:

```bash
sudo nixos-rebuild --rollback
```

This will revert to the previous generation (though it won't fix the SSH issue).
