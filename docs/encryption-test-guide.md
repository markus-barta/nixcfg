# Encryption Test Guide

This guide walks through testing the `encrypt-file` and `decrypt-file` commands to ensure everything works correctly.

## Prerequisites

✅ Make sure you have installed:
```bash
# On macOS
brew install just rage

# On NixOS
nix-shell -p just rage
```

✅ Make sure you're in the repo:
```bash
cd ~/Code/nixcfg  # or your repo location
```

## Test 1: Verify Just Works

```bash
just --list
```

**Expected result:**
- Should show a list of available commands
- Should NOT show any import errors
- `encrypt-file` and `decrypt-file` should be in the `[agenix]` group

**If it fails:** Check that `.shared/common.just` exists

---

## Test 2: Encrypt the Static Leases

```bash
just encrypt-file hosts/miniserver99/static-leases.nix
```

**Expected output:**
```
🔒 Encrypting hosts/miniserver99/static-leases.nix for host: miniserver99
⚠️  Security Note: Your SSH key has no passphrase
   Consider adding one with: ssh-keygen -p -f ~/.ssh/id_rsa
   
🔐 Using your SSH key + miniserver99 host key for encryption
🔍 Validating encryption...
✅ Encryption validated successfully
📝 Added hosts/miniserver99/static-leases.nix to .gitignore
✅ Encrypted to secrets/static-leases-miniserver99.age
✅ Staged secrets/static-leases-miniserver99.age and .gitignore

📝 Ready to commit. Run:
  git commit -m 'backup: update static-leases-miniserver99.age'
```

**What to check:**
- ✅ File created: `secrets/static-leases-miniserver99.age`
- ✅ Added to `.gitignore`: `hosts/miniserver99/static-leases.nix`
- ✅ Staged for commit: `git status` shows both files

**Security warnings (normal):**
- If your SSH key has no passphrase, you'll see a warning (this is good!)
- If the file was ever in Git history, you'll see a warning

---

## Test 3: Verify Git Status

```bash
git status
```

**Expected result:**
```
Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
        modified:   .gitignore
        new file:   secrets/static-leases-miniserver99.age
```

**What to check:**
- ✅ `.gitignore` is staged
- ✅ `secrets/static-leases-miniserver99.age` is staged
- ✅ `hosts/miniserver99/static-leases.nix` is NOT staged (still untracked/ignored)

---

## Test 4: Verify .gitignore Entry

```bash
tail .gitignore
```

**Expected result:**
Should contain:
```gitignore
# Encrypted as static-leases-miniserver99.age - added by just encrypt-file
hosts/miniserver99/static-leases.nix
```

---

## Test 5: Test Decryption (Immediate)

```bash
# Rename original to backup
mv hosts/miniserver99/static-leases.nix hosts/miniserver99/static-leases.nix.original

# Decrypt from encrypted file
just decrypt-file secrets/static-leases-miniserver99.age
```

**Expected output:**
```
🔓 Decrypting secrets/static-leases-miniserver99.age...
✅ Decrypted to hosts/miniserver99/static-leases.nix
```

**Verify content:**
```bash
diff hosts/miniserver99/static-leases.nix.original hosts/miniserver99/static-leases.nix
```

**Expected result:** No differences (files are identical)

**Cleanup:**
```bash
rm hosts/miniserver99/static-leases.nix.original
```

---

## Test 6: Test Auto-detection of Output Path

```bash
# Remove decrypted file
rm hosts/miniserver99/static-leases.nix

# Decrypt without specifying output (should auto-detect)
just decrypt-file secrets/static-leases-miniserver99.age
```

**Expected result:** Should decrypt to `hosts/miniserver99/static-leases.nix` automatically

---

## Test 7: Test Backup Creation

```bash
# Create a test modification
echo "# test comment" >> hosts/miniserver99/static-leases.nix

# Decrypt again (should create backup)
just decrypt-file secrets/static-leases-miniserver99.age hosts/miniserver99/static-leases.nix
```

**Expected output:**
```
📦 Backed up existing file to hosts/miniserver99/static-leases.nix.backup.TIMESTAMP
✅ Decrypted to hosts/miniserver99/static-leases.nix
```

**Verify:**
```bash
ls -la hosts/miniserver99/static-leases.nix.backup.*
```

**Cleanup backups:**
```bash
rm hosts/miniserver99/static-leases.nix.backup.*
```

---

## Test 8: End-to-End Workflow

Simulate the complete workflow:

```bash
# 1. Make a change to static leases
nano hosts/miniserver99/static-leases.nix
# (add a comment or modify something)

# 2. Encrypt for backup
just encrypt-file hosts/miniserver99/static-leases.nix

# 3. Commit to Git
git add -A
git commit -m "test: encryption workflow"

# 4. Remove local file (simulate fresh clone)
rm hosts/miniserver99/static-leases.nix

# 5. Restore from encrypted backup
just decrypt-file secrets/static-leases-miniserver99.age

# 6. Verify file is restored
cat hosts/miniserver99/static-leases.nix
```

**Expected:** Your changes should be preserved through the encrypt/decrypt cycle

---

## Test 9: Cross-Platform Test (Optional)

If you have access to a NixOS machine:

```bash
# On NixOS server (e.g., miniserver99)
cd ~/Code/nixcfg
git pull

# Should be able to decrypt with host key
just decrypt-file secrets/static-leases-miniserver99.age

# Should be able to re-encrypt
just encrypt-file hosts/miniserver99/static-leases.nix
```

**This proves the dual-key encryption works across both machines!**

---

## Cleanup Test Changes

If you made a test commit, you can:

```bash
# Reset to before test commit
git reset HEAD~1

# Or keep the encrypted file but unstage
git reset HEAD

# Check what's staged/unstaged
git status
```

---

## Common Issues & Solutions

### Issue: "rage: not found"

**Solution:**
```bash
# macOS
brew install rage

# NixOS
nix-shell -p rage
```

### Issue: "No SSH public key found"

**Solution:**
```bash
# Generate a new SSH key
ssh-keygen -t ed25519 -C "your@email.com"

# Add passphrase when prompted (recommended!)
```

### Issue: "Could not find HOST in secrets/secrets.nix"

**Solution:** The hostname extracted from the path must exist in `secrets/secrets.nix`. Check:
```bash
grep "miniserver99 =" secrets/secrets.nix
```

### Issue: File path doesn't match `hosts/HOSTNAME/` pattern

**Solution:** Encryption only works for files in the `hosts/HOSTNAME/` directory structure. Move your file there:
```bash
mkdir -p hosts/myhost
mv myfile.conf hosts/myhost/
just encrypt-file hosts/myhost/myfile.conf
```

---

## Security Validation Checklist

After testing, verify these security features are working:

- ✅ **Passphrase reminder**: Warns if SSH key has no passphrase
- ✅ **Git history warning**: Warns if file exists in Git history
- ✅ **Encryption validation**: Tests that encrypted file can be decrypted
- ✅ **Atomic .gitignore**: No race conditions in updating .gitignore
- ✅ **Backup before overwrite**: Creates timestamped backups
- ✅ **Dual-key encryption**: Both your key and host key can decrypt

---

## Success Criteria

✅ All tests pass without errors
✅ Encrypted file can be decrypted on both Mac and NixOS
✅ Original file content is preserved exactly
✅ .gitignore is updated correctly
✅ Security warnings appear when appropriate
✅ Backup files are created when overwriting

**If all tests pass, your encryption setup is production-ready!** 🎉

---

## Next Steps

After successful testing:

1. **Commit the encrypted file:**
   ```bash
   git add secrets/static-leases-miniserver99.age .gitignore
   git commit -m "add: encrypted static-leases backup"
   git push
   ```

2. **Add SSH key passphrase** (if you haven't):
   ```bash
   ssh-keygen -p -f ~/.ssh/id_rsa
   ```

3. **Backup to 1Password:** Store your SSH private key securely

4. **Document the workflow** for future you or team members
