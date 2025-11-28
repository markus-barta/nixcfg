# Migration Issues: miniserver24 → hsb1

**Date**: November 28, 2025  
**Status**: 🟡 ROOT CAUSE FOUND - READY FOR REBOOT TEST  
**Current Generation**: 121 (hsb1 with fixes)  
**Safe Fallback**: Generation 116 (miniserver24)

---

## Summary

Migration from `miniserver24` to `hsb1` initially failed after reboot due to a **restic security wrapper bug** that caused PAM authentication to fail. Root cause has been identified and fixed.

---

## 🔴 ROOT CAUSE IDENTIFIED

### The Actual Problem: Restic Wrapper Capability Duplication

Both `modules/common.nix` AND external hokage defined `security.wrappers.restic` with `capabilities = "cap_dac_read_search=+ep"`.

This resulted in the capability string being duplicated:

```
cap_setpcap,cap_dac_read_search=+ep,cap_dac_read_search=+ep
```

The `setcap` command rejected this invalid capability string, causing **ALL suid wrappers to fail**.

### Chain of Failure

```
1. suid-sgid-wrappers.service FAILS at boot
   ↓
2. /run/wrappers/bin/unix_chkpwd NOT CREATED
   ↓
3. PAM tries to verify password via unix_chkpwd
   ↓
4. PAM error: "helper binary execve failed: No such file or directory"
   ↓
5. SSH denied: "Access denied for user mba by PAM account configuration [preauth]"
```

### Evidence from Journal

```
Nov 28 17:42:43 hsb1 sshd-session[3577]: pam_unix(sshd:account): helper binary execve failed: No such file or directory
Nov 28 17:42:43 hsb1 sshd-session[3575]: fatal: Access denied for user mba by PAM account configuration [preauth]
```

### The Fix Applied

In `modules/common.nix`, use `lib.mkForce` to prevent capability duplication:

```nix
security.wrappers.restic = {
  source = "${pkgs.restic.out}/bin/restic";
  owner = userLogin;
  group = "users";
  permissions = "u=rwx,g=,o=";
  capabilities = lib.mkForce "cap_dac_read_search=+ep";  # mkForce prevents duplication
};
```

---

## Issues Encountered (Chronological)

### Issue 1: SSH Login Fails After First Reboot

**Symptom**: After first `nixos-rebuild switch --flake .#hsb1` and reboot:

- SSH connection closes immediately after key acceptance
- OpenBox login screen appears instead of kiosk autologin

**Initial Misdiagnosis**: Thought it was `initialHashedPassword = ""` conflict

**Actual Cause**: suid-sgid-wrappers.service failure (see root cause above)

---

### Issue 2: PAM Authentication Failure

**Symptom**:

```
fatal: Access denied for user mba by PAM account configuration [preauth]
```

**Actual Cause**: `unix_chkpwd` binary missing due to wrapper service failure

---

### Issue 3: Kiosk Autologin Not Working

**Symptom**: OpenBox/LightDM login screen instead of VLC fullscreen

**Cause**: Display manager starts before user sessions are fully configured

**Fix**: Restart `display-manager.service` after switch, or reboot (now fixed)

---

### Issue 4: Babycam Audio Not Working (After First Fix Attempt)

**Symptom**: Aqara button triggers notification but VLC stays muted

**Cause**: Node-RED still publishing to old MQTT topic `home/miniserver24/kiosk-vlc-volume`

**Fix**: Updated `flows.json` to use `home/hsb1/kiosk-vlc-volume`

---

### Issue 5: TTY Switching Disabled

**Symptom**: `Ctrl+Alt+F2` doesn't switch to text console

**Cause**: OpenBox or X11 grabbing keyboard

**Workaround**: Use GRUB rescue mode or SSH

---

### Issue 6: Rescue Mode Limitations

**Symptom**: In rescue mode:

- `mount` command not found (needed full path `/nix/var/nix/profiles/system/sw/bin/mount`)
- `su - mba` fails with PAM error
- NetworkManager and sshd not running

**Workaround**: Manually start services:

```bash
/nix/var/nix/profiles/system/sw/bin/systemctl start NetworkManager
/nix/var/nix/profiles/system/sw/bin/systemctl start sshd
```

---

## What We Tried (Debug Journey)

| Attempt                              | Result                       |
| ------------------------------------ | ---------------------------- |
| Compare PAM configs (gen 116 vs 118) | Identical - not the cause    |
| Compare sshd configs                 | Only store paths differ      |
| Compare users-groups.json            | hashedPassword correctly set |
| Compare authorized_keys              | Key present in both          |
| Add hashedPassword to configuration  | Didn't fix boot issue        |
| Switch without reboot                | Works fine                   |
| Restart sshd after switch            | Works fine                   |
| Check boot journal (-b -1)           | Found unix_chkpwd error!     |
| Check suid-sgid-wrappers.service     | FAILED with capability error |
| Compare wrapper script               | Found duplicated capability  |

---

## Configuration Changes Made

### 1. modules/common.nix

- Added `lib.mkForce` to restic wrapper capabilities to prevent duplication

```nix
capabilities = lib.mkForce "cap_dac_read_search=+ep";
```

### 2. hosts/hsb1/configuration.nix

- Added explicit `hashedPassword` for mba user (extra safety)
- Added `lib.mkForce` on SSH authorized keys
- **Temporarily enabled** `PasswordAuthentication yes` for SSH (safety fallback)
- Updated MQTT topic to `home/hsb1/kiosk-vlc-volume`

### 3. hosts/hsb0/configuration.nix

- Added `hsb1` and `hsb1.lan` DNS entries
- Kept `miniserver24` as legacy alias (remove after 2025-12-28)

### 4. Node-RED flows.json (on server)

- Updated MQTT topic from `home/miniserver24/kiosk-vlc-volume` to `home/hsb1/kiosk-vlc-volume`

---

## Current Safety Measures

| Protection         | Status             | Purpose                  |
| ------------------ | ------------------ | ------------------------ |
| SSH password auth  | ✅ Enabled         | Fallback if key fails    |
| hashedPassword set | ✅ Configured      | Prevents empty password  |
| unix_chkpwd        | ✅ Now created     | PAM can verify passwords |
| Single SSH key     | ✅ Only user's key | No external hokage keys  |

---

## Verification Commands

```bash
# Check wrapper service succeeded
systemctl status suid-sgid-wrappers.service

# Verify unix_chkpwd exists
ls -la /run/wrappers/bin/unix_chkpwd

# Check restic capabilities (should NOT be duplicated)
getcap /run/wrappers/bin/restic
# Expected: cap_dac_read_search,cap_setpcap=ep

# Check SSH password auth enabled
grep PasswordAuthentication /etc/ssh/sshd_config

# Check authorized key
cat /etc/ssh/authorized_keys.d/mba | ssh-keygen -lf -
```

---

## Recovery Instructions

### If Reboot Fails Again

At GRUB menu:

1. Press any key to stop auto-boot
2. Select **"NixOS - All configurations"**
3. Select **generation 116** (miniserver24, Nov 13)
4. Boot

Then SSH in and investigate:

```bash
ssh mba@192.168.1.101
sudo journalctl -b -1 | grep -E "(suid|wrapper|pam|sshd)" | head -50
```

### If SSH Key Fails

Use password authentication:

```bash
ssh mba@192.168.1.101
# Enter password when prompted
```

---

## Generation History

| Gen | Date         | Config                  | Status                     |
| --- | ------------ | ----------------------- | -------------------------- |
| 116 | Nov 13       | miniserver24            | ✅ Safe fallback           |
| 117 | Nov 28 16:13 | hsb1 (broken)           | ❌ Wrapper failure         |
| 118 | Nov 28 17:38 | hsb1 + password fix     | ❌ Still had wrapper issue |
| 119 | Nov 28 18:07 | hsb1 + mkForce fix      | ✅ Wrapper works           |
| 120 | Nov 28 18:10 | hsb1 + safety fallbacks | ✅ Tested switch           |
| 121 | Nov 28 18:12 | hsb1 (current)          | 🔄 Ready for reboot test   |

---

## Lessons Learned

1. **Check boot journals**: `journalctl -b -1` shows errors from failed boot
2. **suid-sgid-wrappers is critical**: If it fails, PAM breaks completely
3. **External hokage conflicts**: May define same options, use `lib.mkForce`
4. **Switch ≠ Boot**: `nixos-rebuild switch` keeps old processes running
5. **Test boot explicitly**: Services work after switch but may fail on boot
6. **Keep password auth as safety**: Temporarily enable during migrations
7. **Don't add keys you don't own**: The semaphore/yubikey keys are from external hokage (pbek), not user's keys

---

## Post-Migration TODO

After confirming stable reboot:

- [ ] Remove temporary `PasswordAuthentication yes` after 2025-12-15
- [ ] Remove legacy `miniserver24` DNS alias after 2025-12-28
- [ ] Update documentation to reflect hsb1 name
- [ ] Fix atuin daemon error (low priority)
- [ ] Consider adding zoxide `--cmd` conflict fix

---

## 📋 BACKLOG (Fix Later)

### Atuin Daemon Error

**Symptom**: Error on shell startup:

```
Error: failed to connect to local atuin daemon at /home/mba/.local/share/atuin/atuin.sock
Caused by: No such file or directory (os error 2)
```

**Cause**: Atuin disabled in common.nix but fish integration still tries to connect

**Priority**: Low - cosmetic error

---

### Zoxide Double --cmd Error

**Symptom**: On SSH login:

```
error: the argument '--cmd <CMD>' cannot be used multiple times
```

**Cause**: Both common.nix and external hokage configure zoxide with `--cmd cd`

**Priority**: Low - cosmetic error, doesn't prevent login
