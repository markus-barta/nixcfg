# Repository Migration - Switch from pbek to markus-barta

**Date**: November 16, 2025  
**Machine**: msww87 (192.168.1.223)  
**Goal**: Switch from friend's repo to your own fork without breaking anything

---

## Current Situation

### On msww87 (server)

```
Repository: https://github.com/pbek/nixcfg.git (friend's repo)
Commit: 9116a83 (235 commits behind)
Location: ~/nixcfg
```

### On Your Mac (local)

```
Repository: git@github.com:markus-barta/nixcfg.git (your fork)
Commit: eb6b274 (current, includes today's changes)
Location: ~/Code/nixcfg
```

---

## Migration Plan (Safe & Reversible)

### Phase 1: Prepare (Keep Old Repo as Backup)

**SSH into msww87:**

```bash
ssh mba@192.168.1.223
cd ~/nixcfg
```

**Step 1: Rename current remote to 'upstream'**

```bash
# Rename 'origin' to 'upstream' (friend's repo becomes backup)
git remote rename origin upstream

# Verify
git remote -v
# Should show:
# upstream  https://github.com/pbek/nixcfg.git (fetch)
# upstream  https://github.com/pbek/nixcfg.git (push)
```

**Step 2: Add your fork as 'origin'**

```bash
# Add your repo as the new origin
git remote add origin https://github.com/markus-barta/nixcfg.git

# Verify
git remote -v
# Should show:
# origin    https://github.com/markus-barta/nixcfg.git (fetch)
# origin    https://github.com/markus-barta/nixcfg.git (push)
# upstream  https://github.com/pbek/nixcfg.git (fetch)
# upstream  https://github.com/pbek/nixcfg.git (push)
```

---

### Phase 2: Fetch and Switch (No Changes Yet)

**Step 3: Fetch from your fork**

```bash
# Fetch all branches and commits from your fork
git fetch origin

# Check what's available
git branch -a
```

**Step 4: Switch to your fork's main branch**

```bash
# Switch to your fork (this just changes the tracking, doesn't deploy yet)
git checkout -B main origin/main

# Verify you're on your fork
git log -1 --oneline
# Should show: eb6b274 feat(miniserver99): document DHCP Option 15 search domain configuration
# (or a more recent commit if you've pushed changes)

# Check the status
git status
```

---

### Phase 3: Test Configuration (Before Deploying)

**Step 5: Test that the configuration builds**

```bash
# Dry-run build test (doesn't activate anything)
nixos-rebuild dry-build --flake .#msww87

# If successful, you'll see:
# "these 123 derivations will be built"
# "these 456 paths will be fetched"
# No errors = safe to proceed
```

**Important checks:**

- ✅ Build completes without errors
- ✅ No missing files or configurations
- ✅ Your changes (like Gerhard's SSH key) are present

**Verify your changes are in the config:**

```bash
# Check that Gerhard's key is in the config
grep -A 2 "users.users.gb" hosts/msww87/configuration.nix

# Should show the SSH key we just added
```

---

### Phase 4: Deploy (The Actual Switch)

**Step 6: Apply the new configuration**

```bash
# Deploy the configuration from your fork
sudo nixos-rebuild switch --flake .#msww87

# This will:
# - Build the new configuration
# - Switch the system to use it
# - Activate all services
# - Apply your recent changes (like Gerhard's SSH key)
```

**What to expect:**

- System will rebuild (takes a few minutes)
- Services might restart
- SSH connection should stay alive
- System will boot from your config going forward

---

### Phase 5: Verify (Confirm Everything Works)

**Step 7: Test the system**

```bash
# Check system status
systemctl status

# Verify SSH access still works (you're already connected)
hostname
# Should show: msww87

# Check which configuration is active
readlink -f /run/current-system/configuration.nix
# Should point to a new nix store path

# Check git status
git status
# Should show: On branch main, Your branch is up to date with 'origin/main'
```

**Step 8: Test from your Mac**

```bash
# From your Mac, SSH should still work
ssh mba@192.168.1.223

# Test Gerhard's access (if he's available)
# From Gerhard's Mac:
ssh gb@192.168.1.223
```

---

## Rollback Plan (If Something Goes Wrong)

### Emergency Rollback Option 1: Previous Generation

If the new config has issues:

```bash
# List available generations
sudo nixos-rebuild list-generations

# Rollback to previous generation (before the switch)
sudo nixos-rebuild switch --rollback

# This reverts to the old configuration instantly
```

### Emergency Rollback Option 2: Switch Back to Upstream

If you need to go back to friend's repo:

```bash
cd ~/nixcfg

# Switch back to upstream (friend's repo)
git checkout -B main upstream/main

# Deploy the old config
sudo nixos-rebuild switch --flake .#msww87
```

---

## Post-Migration Cleanup (Optional)

Once everything is confirmed working, you can optionally remove the upstream remote:

```bash
# Remove the backup remote (only if you're confident)
git remote remove upstream

# Verify
git remote -v
# Should only show 'origin' now
```

**Recommendation**: Keep `upstream` remote for a while in case you need to reference the original configuration.

---

## Key Differences Between Repos

### Your Fork (markus-barta/nixcfg)

- ✅ Has all your recent changes (Gerhard's SSH key, etc.)
- ✅ 235 commits ahead of the old repo
- ✅ Under your control - you can push/pull freely
- ✅ No dependencies on friend's repo

### Friend's Repo (pbek/nixcfg)

- ⚠️ 235 commits behind
- ⚠️ Doesn't have your recent changes
- ⚠️ You can't push to it (not your repo)
- ✅ Good to keep as reference/upstream

---

## Best Practices Going Forward

### On msww87 (and all your servers)

**Workflow:**

1. Make changes on your Mac in `~/Code/nixcfg`
2. Test locally: `nixos-rebuild build --flake .#msww87`
3. Commit and push to your fork: `git push origin main`
4. SSH to server: `ssh mba@192.168.1.223`
5. Pull and deploy: `cd ~/nixcfg && git pull && sudo nixos-rebuild switch --flake .#msww87`

**Why this works:**

- Your Mac is the "source of truth"
- All servers pull from your fork
- Changes are version controlled
- Easy to deploy to multiple machines

---

## Complete Command Sequence (Copy-Paste Ready)

```bash
# === ON MBA-MSWW87 ===
ssh mba@192.168.1.223

# Navigate to repo
cd ~/nixcfg

# Backup current state (optional but recommended)
git log -1 --oneline > ~/nixcfg-old-commit.txt

# Rename and add remotes
git remote rename origin upstream
git remote add origin https://github.com/markus-barta/nixcfg.git
git fetch origin

# Switch to your fork
git checkout -B main origin/main

# Test build (dry-run)
nixos-rebuild dry-build --flake .#msww87

# If successful, deploy
sudo nixos-rebuild switch --flake .#msww87

# Verify
git remote -v
git status
hostname
systemctl status

# Test SSH from your Mac
# exit
# ssh mba@192.168.1.223  # Should still work
```

---

## Troubleshooting

### Issue: "Permission denied" when fetching

**Cause**: HTTPS authentication required for private repos

**Solution**: Use SSH URL or configure Git credentials

```bash
# Option 1: Use SSH URL (if you have SSH key on server)
git remote set-url origin git@github.com:markus-barta/nixcfg.git

# Option 2: Configure Git credential helper
git config --global credential.helper store
```

### Issue: "Build failed - derivation not found"

**Cause**: Flake inputs might need updating

**Solution**:

```bash
# Update flake inputs
nix flake update

# Try build again
nixos-rebuild dry-build --flake .#msww87
```

### Issue: Configuration file not found

**Cause**: Your fork might have different file structure

**Solution**:

```bash
# Verify the host config exists
ls -la hosts/msww87/

# Check flake outputs
nix flake show
```

---

## Safety Features Built Into This Plan

✅ **No Data Loss**: Old repo kept as `upstream` remote  
✅ **Instant Rollback**: NixOS generations allow rollback with one command  
✅ **Test Before Deploy**: Dry-build validates configuration  
✅ **No Downtime**: System stays running during switch  
✅ **SSH Access Maintained**: Connection doesn't drop during rebuild  
✅ **Version Control**: All changes tracked in Git

---

## Timeline Estimate

- Phase 1 (Prepare): 2 minutes
- Phase 2 (Switch): 1 minute
- Phase 3 (Test): 2 minutes
- Phase 4 (Deploy): 5-10 minutes (depends on downloads)
- Phase 5 (Verify): 2 minutes

**Total**: ~15-20 minutes

---

## Next Steps After Migration

Once the migration is complete:

1. **[ ] Test Gerhard's SSH access** with the new key
2. **[ ] Configure static IP 192.168.1.100** (separate task)
3. **[ ] Update all other servers** to use your fork (miniserver99, miniserver24, etc.)
4. **[ ] Document the migration** in main README

---

## Related Documentation

- [msww87 Server Notes](./msww87-server-notes.md)
- [SSH Key Configuration](./ssh-key-gerhard-added.md)
- [Static IP Setup](./msww87-setup-steps.md)

---

**Ready to proceed?** Follow the command sequence above and you'll be switched to your fork safely! 🚀
