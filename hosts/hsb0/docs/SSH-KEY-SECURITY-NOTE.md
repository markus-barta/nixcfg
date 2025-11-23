# hsb0 - SSH Key Security Notice

**Date**: 2025-11-22
**Priority**: HIGH - Review before hokage migration
**Related**: `MIGRATION-PLAN-HOKAGE.md`

## Issue

The hokage `server-home.nix` module (from `github:pbek/nixcfg`) automatically injects Patrizio's SSH keys into ALL users defined in `hokage.users`:

- `omega@yubikey` - Yubikey public key
- `omega@rsa` - RSA public key
- `omega@tuvb` - Legacy RSA key
- `omega@semaphore` - Semaphore key

**Security Risk**: External developer gains SSH access to personal/family servers.

## What hsb0 Needs

- `mba` user: Markus' SSH key ONLY
- NO external access (omega/Yubikey)

## Required Addition to Migration Plan

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

## Verification After Deployment

```bash
# Check authorized keys on hsb0
ssh mba@hsb0 'cat ~/.ssh/authorized_keys'

# Should show ONLY your key, NOT omega keys
```

## Standard Practice Going Forward

**All MBA servers** using hokage `server-home` role MUST explicitly override SSH keys with `lib.mkForce`.

Template for future servers:

```nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # mba@markus
    # Add wife's key when available
  ];
};
```

---

**Action**: Update `MIGRATION-PLAN-HOKAGE.md` Phase 2.5 to include SSH key override before executing migration.
