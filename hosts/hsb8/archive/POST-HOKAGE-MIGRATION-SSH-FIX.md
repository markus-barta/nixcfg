# hsb8 - Post-Hokage Migration SSH Key Fix

**Status**: 🚨 CRITICAL - Server locked out after reboot
**Date**: 2025-11-22
**Issue**: SSH access lost for `mba` user after hokage migration

## Problem

**Root Cause**: The hokage `server-home.nix` module automatically adds Patrizio's SSH keys (omega@yubikey, omega@rsa, etc.) to ALL users in `hokage.users`. This overwrites/conflicts with our explicit key configuration.

**Security Issue**: External developer (Patrizio/omega) has SSH access to personal family servers - NOT ACCEPTABLE.

## What We Need

**hsb8 (Parents' server)**:

- `mba` user: Markus' SSH key only
- `gb` user: Gerhard's (father) SSH key only
- NO omega/Yubikey keys

**All MBA servers**:

- `mba` user: Markus' SSH key only
- Future: Wife's SSH key
- NO omega/Yubikey keys

## The Fix

The hokage `server-home.nix` uses `lib.genAttrs hokage.users` to add keys to ALL users. We need to either:

1. **Option A**: Override after hokage sets keys (use `lib.mkForce`)
2. **Option B**: Fork/customize the hokage module to not inject keys
3. **Option C**: Use a different hokage role that doesn't auto-configure SSH

**Recommended**: Option A - explicit override in `configuration.nix`

## Implementation

Add to `hosts/hsb8/configuration.nix` (after networking config, before hokage block):

```nix
# Override hokage's SSH key injection - we manage our own keys
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # mba@markus
  ];
};

users.users.gb = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71qYnLJnq0PPs/PWR0O+0zvEQfT7QYaHbrPUdILnK5jqZTj6o02kyfce6JLk+xyYhI596T6DD9But943cKFY/cYG037EjlECq+LXdS7bRsb8wYdc8vjcyF21Ol6gSJdT3noAzkZnqnucnvd7D1lae2ZVw7km6GQvz5XQGS/LQ38JpPZ2JYb0ufT3Z1vgigq9GqhCU6C7NdUslJJJ1Lj4JfPqQTbS1ihZqMe3SQ+ctfmHNYniUkd5Potu7wLMG1OJDL13BXu/M5IihgerZ3QuPb2VPQkb37oxKfquMKveYL9bt4fmK+7+CRHJnzFB45HfG5PiTKsyjuPR5A1N3U5Os+9Wrav9YrqDHWjCaFI1EIY4HRM/kRufD+0ncvvXpsp4foS9DAhK5g3OObRlKgPEc4hkD7hC2KBXUt7Kyg6SLL89gD42qSXLxZlxaTD65UaqB28PuOt7+LtKEPhm1jfH65cKu5vGqUp3145hSJuHB4FuA0ieplfxO78psVM=" # gb@gerhard
  ];
};
```

**Key Point**: `lib.mkForce` overrides hokage's default keys completely.

## Recovery Steps

1. Physical access to hsb8 (keyboard/monitor)
2. Login locally
3. `cd ~/nixcfg && git pull`
4. `sudo nixos-rebuild switch --flake .#hsb8`
5. Test: `ssh mba@192.168.1.100`

## Apply to Other Servers

**hsb0**: Add same SSH key override pattern
**Future servers**: Always use `lib.mkForce` for SSH keys when using hokage

---

**Lesson**: External hokage modules may inject unwanted configuration. Always audit and override security-critical settings (SSH keys, firewall, secrets).
