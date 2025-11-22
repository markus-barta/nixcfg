# hsb8 - Passwordless Sudo Deployment (Safe Method)

**Date**: 2025-11-22
**Status**: Ready to deploy
**Risk Level**: LOW (with rollback plan)

## Current Situation

- ✅ SSH working (key-based, no password)
- ✅ Configuration correct (passwordless sudo added)
- ❌ Activation pending (requires sudo password once)
- 🔐 User password: Set to `1234` (temporary recovery)

## What We're Deploying

```nix
# Added to hosts/hsb8/configuration.nix
security.sudo-rs.wheelNeedsPassword = false;
```

**Effect**: Members of `wheel` group (you) can run `sudo` without password.

## Why This Is Safe

1. **SSH still requires key** - Can't SSH without your key
2. **Only affects local sudo** - Once you're SSH'd in
3. **Easy rollback** - If something breaks: `sudo nixos-rebuild --rollback`
4. **Keeps temp password** - `1234` stays as fallback

## Deployment Steps

### Step 1: Deploy with Current Password

```bash
# From your Mac (you'll be prompted for password '1234')
ssh -t mba@192.168.1.100 'cd ~/nixcfg && sudo nixos-rebuild switch --flake .#hsb8'
# Enter: 1234
```

### Step 2: Test Passwordless Sudo

```bash
# Should work WITHOUT password now
ssh mba@192.168.1.100 'sudo whoami'
# Expected output: root (no password prompt)
```

### Step 3: Test GB User SSH (After Step 1)

```bash
# Your father should be able to SSH now
ssh gb@192.168.1.100 'echo "GB user working!"'
```

### Step 4: Verify Remote Deployment Works

```bash
ssh mba@192.168.1.100 'cd ~/nixcfg && just s'
# Should work without password!
```

## About Your Password

### Option A: Keep Password (Recommended)

**Pros**:

- ✅ Physical console fallback if SSH breaks
- ✅ Recovery option if something goes wrong
- ✅ Can still login locally

**Cons**:

- ⚠️ Need to remember it (but it's just for emergencies)

**How**: Do nothing - the password stays

### Option B: Remove Password (Advanced)

**Pros**:

- ✅ True passwordless system
- ✅ Forces SSH-only access

**Cons**:

- ⚠️ If SSH breaks, you CANNOT login at physical console
- ⚠️ Requires USB rescue disk to recover
- ⚠️ More risky

**How**: Add to configuration:

```nix
users.users.mba = {
  hashedPassword = "!";  # Disables password login
  openssh.authorizedKeys.keys = lib.mkForce [ ... ];
};
```

## My Recommendation

**Keep the password (`1234`) for now**. Here's why:

1. **Safety Net**: If SSH breaks again (it happened once!), you can login at console
2. **Low Risk**: Only works at physical console (not over SSH)
3. **Best Practice**: Even servers need emergency access
4. **Later**: Once system is stable at parents' home (ww87), you can remove it

## Alternative: Strong Password

If `1234` bothers you, set a proper password:

```bash
ssh mba@192.168.1.100
sudo passwd mba
# Set something strong like: correct-horse-battery-staple
```

You'll rarely use it (only physical console emergencies).

## Emergency Rollback

If deployment breaks something:

```bash
# At physical console
sudo nixos-rebuild --rollback
```

This reverts to previous generation (before passwordless sudo).

## Summary

**Current**: SSH works (key), sudo needs password  
**After Deploy**: SSH works (key), sudo passwordless  
**Password `1234`**: Keeps working as physical console fallback

**Bottom Line**: Deploy with password once, then everything becomes truly passwordless for remote work. The password stays as emergency backup (which is good!).
