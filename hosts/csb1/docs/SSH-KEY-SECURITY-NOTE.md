# csb1 - SSH Key Security Notice

**Date**: 2025-11-29  
**Priority**: 🔴 HIGH - Review before hokage migration  
**Related**: `MIGRATION-PLAN-HOKAGE.md`

---

## ⚠️ Issue

The hokage `server-remote.nix` module (from `github:pbek/nixcfg`) automatically injects Patrizio's SSH keys into ALL users defined in `hokage.users`:

- `omega@yubikey` - Yubikey public key
- `omega@rsa` - RSA public key
- `omega@tuvb` - Legacy RSA key
- `omega@semaphore` - Semaphore key

**Security Risk**: External developer gains SSH access to personal servers.

---

## 🔒 What csb1 Needs

- `mba` user: Markus' SSH key ONLY
- NO external access (omega/Yubikey)

---

## 🛠️ Required Fix in Configuration

**Phase 2.5** (after hokage configuration, before testing) - Add explicit SSH key override:

```nix
# Override hokage's SSH key injection
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # mba@markus
  ];
};
```

**Why `lib.mkForce`**: Completely replaces hokage's key list instead of appending.

---

## ✅ Verification After Deployment

```bash
# Check authorized keys on csb1
ssh -p 2222 mba@<hostname> 'cat ~/.ssh/authorized_keys'

# Should show ONLY your key, NOT omega keys:
# ✅ mba@markus
# ❌ omega@yubikey
# ❌ omega@rsa
# ❌ omega@tuvb
# ❌ omega@semaphore
```

---

## 📋 Standard Practice for All Servers

**All servers** using external hokage consumer pattern MUST explicitly override SSH keys with `lib.mkForce`.

Template:

```nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # mba@markus
    # Add additional authorized keys as needed
  ];
};
```

---

## 🚨 Incident Reference

On November 22, 2025, hsb8 suffered complete SSH lockout after switching to external hokage. Only omega keys were present, requiring physical console access to recover.

**Root Cause**: The `serverMba.enable` mixin was providing the SSH key, which was lost when switching to explicit hokage options.

**This MUST NOT happen to csb1** - apply the `lib.mkForce` fix!

---

**Action**: Ensure `lib.mkForce` SSH key override is in place BEFORE executing migration.
