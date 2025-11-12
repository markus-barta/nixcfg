# Pre-Flight Testing Checklist

Quick validation checklist before running the full test suite.

## ✅ Prerequisites Check

```bash
cd ~/Code/nixcfg

# 1. Verify just is installed
just --version
# Expected: just X.X.X

# 2. Verify rage is installed  
rage --version
# Expected: rage X.X.X

# 3. Verify SSH key exists
ls -la ~/.ssh/id_*.pub
# Expected: At least one public key file

# 4. Verify justfile works
just --list
# Expected: List of commands, no errors

# 5. Verify static-leases.nix exists
ls -la hosts/miniserver99/static-leases.nix
# Expected: File exists with ~137 lines
```

## 🧪 Quick Smoke Test

```bash
# Single command test
just encrypt-file hosts/miniserver99/static-leases.nix

# Expected output:
# - 🔒 Encrypting message
# - ⚠️  Security warnings (if applicable)
# - 🔐 Encryption message
# - 🔍 Validation message
# - ✅ Success messages
# - File created: secrets/static-leases-miniserver99.age
```

## 🔍 Validation

```bash
# 1. Check encrypted file was created
ls -la secrets/static-leases-miniserver99.age
# Expected: File exists, reasonable size

# 2. Check .gitignore was updated
git diff .gitignore
# Expected: Shows added entry for static-leases.nix

# 3. Test immediate decryption
mv hosts/miniserver99/static-leases.nix hosts/miniserver99/static-leases.nix.backup
just decrypt-file secrets/static-leases-miniserver99.age
diff hosts/miniserver99/static-leases.nix.backup hosts/miniserver99/static-leases.nix
# Expected: No differences

# 4. Cleanup
rm hosts/miniserver99/static-leases.nix.backup
```

## 🎯 Ready to Test?

If all checks pass above, proceed to the full test guide:

```bash
# View full test guide
cat docs/encryption-test-guide.md

# Or open in your editor
nano docs/encryption-test-guide.md
```

## ⚠️ If Anything Fails

1. **just command not found**
   ```bash
   brew install just  # macOS
   ```

2. **rage command not found**
   ```bash
   brew install rage  # macOS
   ```

3. **No SSH key**
   ```bash
   ssh-keygen -t ed25519 -C "your@email.com"
   ```

4. **Import error (.shared/common.just)**
   - Check that file exists: `ls -la .shared/common.just`
   - If missing, it should be in Git: `git status .shared/common.just`

## 📋 What Gets Tested

The full test suite validates:

- [x] Basic encryption/decryption
- [x] Dual-key encryption (your key + host key)
- [x] Automatic .gitignore updates
- [x] Backup file creation
- [x] Security warnings (passphrase, git history)
- [x] Encryption validation
- [x] Auto-detection of output paths
- [x] Cross-platform compatibility

## 🚀 Post-Testing

After successful tests:

```bash
# Commit the encrypted backup
git add secrets/static-leases-miniserver99.age .gitignore
git commit -m "add: encrypted static-leases backup"
git push

# Document success
echo "✅ Encryption tested successfully on $(date)" >> docs/test-results.log
```

---

**Estimated time:** 5-10 minutes for full test suite
**Difficulty:** Easy - just follow the guide!

