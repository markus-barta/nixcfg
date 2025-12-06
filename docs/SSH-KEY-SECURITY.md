# SSH Key Security for External Hokage Consumers

**Last Updated**: 2025-12-06
**Applies to**: All servers using external hokage from `github:pbek/nixcfg`

---

## ⚠️ The Problem

When using external Hokage modules, the `server-remote` role automatically injects SSH keys for omega (Patrizio):

- `omega@yubikey` (sk-ecdsa)
- `omega@rsa` (ssh-rsa)
- `omega@semaphore` (ssh-ed25519)

**Without override**: Both your keys AND omega keys are accepted = security risk.

---

## 🛠️ The Solution

Use `lib.mkForce` to REPLACE (not merge) the SSH keys:

```nix
# In configuration.nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    # ONLY these keys can access:
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABA..." # markus@iMac
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..." # hsb1/Node-RED automation
  ];

  # Emergency password (generate with: mkpasswd -m yescrypt)
  hashedPassword = "$y$j9T$...";
};

# TEMPORARY: Enable password auth during migration
services.openssh.settings.PasswordAuthentication = lib.mkForce true;

# Passwordless sudo
security.sudo-rs.wheelNeedsPassword = false;
```

**Why `lib.mkForce`**: Completely replaces hokage's key list instead of appending.

---

## ✅ Verification

After deployment, verify no omega keys exist:

```bash
ssh -p 2222 mba@<hostname> 'grep -c "omega" ~/.ssh/authorized_keys'
# Expected: 0
```

---

## 📚 Incident History

### hsb8 Incident (2025-11-22)

- After migration, omega keys were injected
- Unexpected access was possible
- **Fix**: Added `lib.mkForce` override

### hsb1 Lockout (2025-11-28)

- Migration used `lib.mkForce` for keys ✅
- But hokage also set `PasswordAuthentication = no`
- No password was set → Complete lockout!
- **Fix**: Enable temporary password auth + set hashedPassword

### csb1 Incident (2025-12-05)

- Network lost during deploy (NetworkManager issue)
- VNC recovery needed but no password set
- **Fix**: Static IP config + hashedPassword in config

### csb0 Incident (2025-12-06)

- Wrong subnet (/24 vs /22) and gateway caused lockout
- VNC keyboard issues made recovery difficult
- **Fix**: DHCP analysis to get correct network values

---

## 📋 Complete Template

```nix
{ config, lib, ... }:

{
  # ============================================================================
  # 🚨 SSH KEY SECURITY - CRITICAL FOR EXTERNAL HOKAGE
  # ============================================================================
  users.users.mba = {
    openssh.authorizedKeys.keys = lib.mkForce [
      # markus@iMac-5k-MBA-home.local (id_rsa)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABA..."
      # hsb1 (miniserver24): Node-RED container SSH automation
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..."
    ];

    # Recovery password - from 1Password "csb0 csb1 recovery"
    hashedPassword = "$6$...";
  };

  # ============================================================================
  # 🔐 SSH SETTINGS
  # ============================================================================
  # Temporary during migration - disable after verification
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  # ============================================================================
  # 🔓 PASSWORDLESS SUDO
  # ============================================================================
  security.sudo-rs.wheelNeedsPassword = false;
}
```

---

## 🎯 Post-Migration Hardening

After verifying SSH key login works:

```nix
# Remove or set to false:
services.openssh.settings.PasswordAuthentication = false;
```

---

**Standard Practice**: ALL servers using external hokage consumer pattern MUST:

1. Use `lib.mkForce` for SSH key override
2. Set `hashedPassword` for VNC recovery
3. Temporarily enable password auth during migration
4. Verify no omega keys after deployment
