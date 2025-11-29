# T10: Rollback Test

**Feature ID**: F10  
**Status**: ⏳ Pending  
**Purpose**: Verify NixOS generation rollback capability

## Overview

Tests that NixOS generation rollback works correctly. This is your safety net if migration fails.

## ⚠️ WARNING

**This test can disrupt services!** Only run:

- During maintenance windows
- When you have console access ready
- After taking a pre-migration snapshot (T08)

## Prerequisites

- SSH access to csb1 (port 2222)
- At least 2 NixOS generations available
- VNC console access ready (in case SSH breaks)

## Rollback Methods

### Method 1: nixos-rebuild (Recommended)

```bash
# List generations
ssh -p 2222 mba@cs1.barta.cm 'sudo nixos-rebuild list-generations'

# Rollback to previous generation
ssh -p 2222 mba@cs1.barta.cm 'sudo nixos-rebuild switch --rollback'

# Or switch to specific generation
ssh -p 2222 mba@cs1.barta.cm 'sudo nixos-rebuild switch --switch-generation 42'
```

### Method 2: Boot Menu (If SSH Broken)

1. Access Netcup VNC Console (see secrets/RUNBOOK.md)
2. Reboot server via VNC or Netcup panel
3. In GRUB menu, select previous generation
4. Boot into working configuration
5. Fix the broken configuration

### Method 3: Recovery Mode (Last Resort)

1. Access Netcup Server Control Panel
2. Boot into recovery/rescue mode
3. Mount ZFS pools
4. Edit configuration
5. Rebuild NixOS

## Test Procedure (Non-Destructive)

### Step 1: Verify Generations Exist

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo nixos-rebuild list-generations | head -10
```

**Expected**: Multiple generations listed

### Step 2: Check Current Generation

```bash
readlink /nix/var/nix/profiles/system
```

**Expected**: Shows current generation number

### Step 3: Dry Run Rollback

```bash
# This is safe - doesn't actually switch
sudo nixos-rebuild dry-build --rollback
```

**Expected**: Shows what would change

### Step 4: Verify GRUB Entries

```bash
ls /boot/grub/
cat /boot/grub/grub.cfg | grep menuentry | head -10
```

**Expected**: Multiple boot entries for different generations

## Automated Test (Safe)

```bash
./tests/T10-rollback-test.sh
```

This script only verifies rollback capability, does NOT actually rollback.

## Emergency Rollback Commands

Save these commands for emergency:

```bash
# Quick rollback
sudo nixos-rebuild switch --rollback

# Rollback and reboot
sudo nixos-rebuild boot --rollback && sudo reboot

# List all generations first
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nixos-rebuild switch --switch-generation <NUMBER>
```

## VNC Console Access

If SSH is broken, use Netcup VNC:

1. **URL**: https://www.servercontrolpanel.de/SCP
2. **Customer**: See secrets/RUNBOOK.md
3. **2FA**: Required
4. Navigate to server → VNC Console
5. Login as `mba` with password from RUNBOOK.md

## Success Criteria

- ✅ Multiple generations available
- ✅ GRUB entries for generations exist
- ✅ Rollback command would succeed (dry run)
- ✅ VNC console access documented

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
