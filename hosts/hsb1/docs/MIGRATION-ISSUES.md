# Migration Issues: miniserver24 → hsb1

**Date**: November 28, 2025  
**Status**: 🔴 ROLLBACK REQUIRED  
**Rolled back to**: Generation 116 (miniserver24)

---

## Summary

Migration from `miniserver24` to `hsb1` failed after reboot. System boots but authentication is broken.

---

## Issues Encountered

### 1. SSH Connection Immediately Closes

**Symptom**: SSH key accepted, then connection closes immediately

```
debug1: Server accepts key: /Users/markus/.ssh/id_rsa
Connection closed by 192.168.1.101 port 22
```

**Cause**: Unknown - possibly PAM or user shell issue

---

### 2. PAM Authentication Failure

**Symptom**:

```
fatal: Access denied for user mba by PAM account configuration [preauth]
```

**Observed in**:

- SSH login attempts
- `su - mba` command

**Root cause**: Possibly related to `initialHashedPassword = ""` in common.nix conflicting with password set via `passwd`

---

### 3. Kiosk Autologin Not Working

**Symptom**: After reboot, system shows OpenBox/LightDM login screen instead of auto-logging in kiosk user and starting VLC

**Expected**: Kiosk user auto-login → OpenBox → VLC fullscreen babycam

---

### 4. TTY Switching Disabled

**Symptom**: `Ctrl+Alt+F2` (F3, F4, etc.) does not switch to text console

**Cause**: Possibly OpenBox or X11 configuration grabbing all inputs

---

### 5. Rescue Mode Limitations

**Symptom**: In `systemd.unit=rescue.target` mode:

- `su - mba` fails with PAM error
- Some services not available
- Had to manually start NetworkManager, sshd

---

## What Worked Before Rollback

- ✅ Hostname changed to `hsb1`
- ✅ Docker services running (all 11 containers)
- ✅ Babycam video working (after display-manager restart)
- ✅ Audio control working (after Node-RED topic fix)
- ✅ DNS resolution (hsb1 and miniserver24 both resolve)

---

## Configuration Changes Made

### 1. flake.nix

- Replaced `mkServerHost "miniserver24"` with external hokage pattern for hsb1
- Removed unused `mkServerHost` helper

### 2. hosts/hsb1/configuration.nix

- Removed local hokage import
- Added external hokage block with `role = "server-home"`
- Added SSH key security with `lib.mkForce`
- Added `security.sudo-rs.wheelNeedsPassword = false`
- Updated MQTT topic to `home/hsb1/kiosk-vlc-volume`

### 3. modules/common.nix

- Added `mkDefault` wrappers for external hokage compatibility
- Removed duplicate nixpkgs symlink (provided by external hokage)

### 4. hosts/hsb0/configuration.nix

- Added `hsb1` and `hsb1.lan` DNS entries
- Kept `miniserver24` as legacy alias

### 5. Node-RED flows.json (on server)

- Updated MQTT topic from `home/miniserver24/kiosk-vlc-volume` to `home/hsb1/kiosk-vlc-volume`

---

## Root Cause Found ✅

### The Problem: Empty Password Hash

The `common.nix` module sets `initialHashedPassword = ""` for all users via `hokage.users`.

When hsb1 activated for the first time with external hokage:

1. NixOS created the mba user with **empty password**
2. PAM rejected SSH login because account has no valid password
3. Error: `Access denied for user mba by PAM account configuration [preauth]`

### The Fix

Add explicit `hashedPassword` to mba user in `hosts/hsb1/configuration.nix`:

```nix
users.users.mba = {
  hashedPassword = "$y$j9T$bi9LmgTpnV.EleK4RduzQ/$eLkQ9o8n/Ix7YneRJBUNSdK6tCxAwwSYR.wL08wu1H/";
  openssh.authorizedKeys.keys = lib.mkForce [ ... ];
};
```

This overrides `initialHashedPassword = ""` from common.nix.

### Why hsb0 Worked

hsb0 had an existing password set before migrating to external hokage. The `initialHashedPassword` only applies on **user creation**, not updates. Since hsb0's mba user already existed with a password, it wasn't affected.

---

## Recovery Steps Taken

1. Rebooted → Got OpenBox login screen (no autologin)
2. Tried Ctrl+Alt+F2-F6 → No response
3. Booted with `init=/bin/sh` → Limited shell, mount not found
4. Booted with `systemd.unit=rescue.target` → Got root shell
5. Set passwords with `passwd mba` and `passwd root`
6. Started NetworkManager and sshd manually
7. SSH still fails with PAM error
8. **Decision: Roll back to generation 116**

---

## Next Steps (After Rollback)

1. [ ] Boot generation 116 (working miniserver24)
2. [ ] SSH in and verify everything works
3. [ ] Investigate PAM configuration differences between local and external hokage
4. [ ] Check `initialHashedPassword` handling
5. [ ] Check display manager autologin configuration
6. [ ] Test hsb1 config in a VM before deploying to production
7. [ ] Consider keeping miniserver24 name if migration too risky

---

## Rollback Instructions

At GRUB menu:

1. Press any key to stop auto-boot
2. Select **"NixOS - All configurations"**
3. Select **generation 116** (Nov 13, 2025)
4. Boot

This boots the working `miniserver24` configuration.

---

## Investigation Results (Post-Rollback)

### PAM Config Comparison

- PAM sshd configs are **identical** between gen 116 and 117
- nsswitch.conf is **identical** between generations
- sshd_config only differs in nix store paths (openssh version)

### What's NOT the Cause

- ❌ PAM configuration differences
- ❌ nsswitch.conf
- ❌ sshd_config

### Still Unknown

- The actual error was `Access denied for user mba by PAM account configuration [preauth]`
- This occurs AFTER key authentication succeeds
- Might be related to systemd service startup order
- Might be related to nscd not starting before sshd
- passwd/shadow files are generated at activation time, can't compare directly

## Files to Review

- External hokage's `common.nix` - Check user/PAM configuration
- `security.pam` NixOS options - May need explicit configuration
- `services.nscd` - Ensure it starts before sshd
- `systemd.services.sshd.after` - Check dependencies

---

## Lessons Learned

1. **Test in VM first** - Don't migrate production smart home server without VM testing
2. **Have physical keyboard with correct layout** - Recovery is painful without it
3. **External hokage has different defaults** - May need more explicit configuration
4. **Keep rollback generation noted** - Generation 116 is the safe fallback
5. **Always set explicit hashedPassword** - Don't rely on initialHashedPassword for external hokage

---

## 📋 BACKLOG (Fix Later)

### Atuin Daemon Error

**Symptom**: Error on shell startup:

```
Error: failed to connect to local atuin daemon at /home/mba/.local/share/atuin/atuin.sock
Caused by: No such file or directory (os error 2)
```

**Cause**: Atuin is disabled in common.nix (`hokage.programs.atuin.enable = false`) but fish integration may still try to connect.

**Priority**: Low - cosmetic error, doesn't affect functionality

**Fix**: TBD - either fully remove atuin integration or ensure daemon starts
