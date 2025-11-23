# TODO: Secrets Management with Age

**Last Updated**: 2025-11-15  
**Status**: Planning Phase

---

## Overview

Implement encrypted secrets management using `age` encryption, similar to miniserver99's approach but for the entire `~/Secrets/` directory.

**Goals**:

- ✅ Encrypt sensitive files (API keys, .env files, SSH keys, certificates)
- ✅ Version control encrypted files in git
- ✅ Keep decrypted files local only (gitignored)
- ✅ Simple encryption/decryption workflow
- ✅ Safe key management strategy

---

## Design Decisions Needed

### 1. Key Management Strategy

**Option A: Use Existing SSH Key (Recommended)** ⭐

```bash
# Encrypt with SSH public key
age -R ~/.ssh/id_rsa.pub -o file.age file.txt

# Decrypt with SSH private key
age -d -i ~/.ssh/id_rsa file.age > file.txt
```

**Pros**:

- ✅ No new keys to manage
- ✅ SSH key already backed up
- ✅ Simpler workflow

**Cons**:

- ❌ SSH key compromise = secrets compromise
- ❌ SSH key rotation requires re-encrypting all secrets

**Option B: Dedicated Age Key**

```bash
# Generate new age key
age-keygen -o ~/Secrets/.keys/age-key.txt

# Encrypt/decrypt with age key
age -r age1... -o file.age file.txt
age -d -i ~/Secrets/.keys/age-key.txt file.age > file.txt
```

**Pros**:

- ✅ Separate key for secrets (isolation)
- ✅ Can have multiple recipients (team access)

**Cons**:

- ❌ One more key to backup and manage
- ❌ Key loss = all secrets lost

**Decision**: [ ] Choose Option A or B

---

### 2. Directory Structure

```
~/Secrets/
├── encrypted/              # ✅ Git-tracked
│   ├── personal/
│   │   ├── .env.personal.age
│   │   ├── api-keys/
│   │   │   ├── openai.age
│   │   │   ├── github.age
│   │   │   └── aws.age
│   │   └── ssh-keys/
│   │       └── id_rsa_personal.age
│   │
│   ├── work/               # Optional: Separate work secrets
│   │   ├── .env.work.age
│   │   ├── api-keys/
│   │   └── ssh-keys/
│   │
│   └── shared/             # Optional: Shared between machines
│       └── certificates/
│           └── cert.pem.age
│
├── decrypted/              # ❌ Gitignored
│   ├── personal/
│   │   ├── .env.personal
│   │   ├── api-keys/
│   │   └── ssh-keys/
│   ├── work/
│   └── shared/
│   └── .example           # ✅ Tracked: Example/template file
│
├── scripts/                # ✅ Git-tracked
│   ├── encrypt-all.sh     # Encrypt decrypted/ → encrypted/
│   ├── decrypt-all.sh     # Decrypt encrypted/ → decrypted/
│   ├── encrypt-file.sh    # Encrypt single file
│   ├── decrypt-file.sh    # Decrypt single file
│   ├── verify-integrity.sh # Check all files can decrypt
│   └── rotate-key.sh      # Re-encrypt with new key
│
├── .gitignore             # ✅ Tracked
├── .keys/                 # ❌ Gitignored (if using dedicated age key)
│   └── age-key.txt        # Private key (NOT in git)
├── keys.txt               # ✅ Tracked (age public keys, if using dedicated)
└── README.md              # ✅ Tracked
```

**Decision**: [ ] Approve structure or suggest changes

---

### 3. Workflow Preferences

**Manual Workflow** (Recommended for Security) ⭐

```bash
# 1. Edit files in decrypted/
vim ~/Secrets/decrypted/personal/.env.personal

# 2. Manually encrypt when ready
cd ~/Secrets
./scripts/encrypt-all.sh

# 3. Review changes and commit
git diff encrypted/
git add encrypted/
git commit -m "Update API keys"
git push

# 4. On another machine
git pull
./scripts/decrypt-all.sh
```

**Auto-Sync Workflow** (Convenience vs Security Tradeoff)

```bash
# Auto-decrypt on shell start (if encrypted/ is newer)
# Add to ~/.config/fish/config.fish
if test -d ~/Secrets/encrypted
    ~/Secrets/scripts/auto-sync.sh  # Decrypts if needed
end
```

**Decision**: [ ] Manual (recommended) or Auto-sync?

---

### 4. What Goes in Secrets?

**High Priority** (Start with these):

- [ ] `.env` files with API keys
- [ ] API tokens (OpenAI, GitHub, AWS, etc.)
- [ ] OAuth tokens
- [ ] Webhook secrets
- [ ] Database connection strings (if any)

**Medium Priority**:

- [ ] SSH private keys (alternative to ~/.ssh/)
  - Note: Keep ~/.ssh/ as primary, backup here?
- [ ] GPG keys (backup)
- [ ] TLS/SSL certificates (if any)

**Low Priority / Not Recommended**:

- ❌ Passwords (use password manager instead)
- ❌ Large files (age is for text/keys, not binaries)
- ❌ Frequently changing data

**Decision**: [ ] List specific secrets to manage

---

### 5. Multi-Machine Strategy

**Scenario**: Home iMac (personal) vs Work laptop (work + personal)

**Option A: Single Repo with Subdirectories** ⭐

```
encrypted/
├── personal/   # Home + work laptop
└── work/       # Only work laptop
```

Decrypt selectively:

```bash
# Home iMac: Only personal
./scripts/decrypt-file.sh encrypted/personal/.env.personal.age

# Work laptop: Both
./scripts/decrypt-all.sh
```

**Option B: Separate Git Repos**

```
~/Secrets/         # Personal repo
~/Secrets-Work/    # Work repo (separate private)
```

**Decision**: [ ] Choose Option A (recommended) or B

---

### 6. Nix/home-manager Integration

**Option 1: Manual (Recommended)** ⭐

- Keep secrets management separate from Nix
- Manual `./scripts/decrypt-all.sh` when needed
- Simpler, more secure

**Option 2: home-manager Activation**

```nix
# home.nix
home.activation.decryptSecrets = lib.hm.dag.entryAfter ["writeBoundary"] ''
  if [ -d "$HOME/Secrets/encrypted" ]; then
    echo "Decrypting secrets..."
    $HOME/Secrets/scripts/decrypt-all.sh
  fi
'';
```

**Pros**: Automatic on `home-manager switch`  
**Cons**: Secrets decrypted automatically (less control)

**Decision**: [ ] Manual (recommended) or Integrated?

---

## Implementation Plan

### Phase 1: Setup (Day 1)

- [ ] Install/verify `age` package

  ```bash
  # Check if already installed (Homebrew has it)
  which age

  # If migrating to Nix
  # Add to home.nix: pkgs.age
  ```

- [ ] Choose key management strategy (Option A or B above)
- [ ] Generate/configure keys

- [ ] Create directory structure

  ```bash
  mkdir -p ~/Secrets/{encrypted,decrypted,scripts,.keys}
  mkdir -p ~/Secrets/encrypted/{personal,work,shared}
  mkdir -p ~/Secrets/decrypted/{personal,work,shared}
  ```

- [ ] Create `.gitignore`

  ```gitignore
  # Decrypted files (never commit!)
  decrypted/

  # Private keys (never commit!)
  .keys/

  # Except example file
  !decrypted/.example
  ```

### Phase 2: Write Scripts (Day 1-2)

- [ ] `scripts/encrypt-file.sh`
  - Encrypt single file: `decrypted/path/file → encrypted/path/file.age`
  - Preserve directory structure

- [ ] `scripts/decrypt-file.sh`
  - Decrypt single file: `encrypted/path/file.age → decrypted/path/file`
  - Preserve directory structure

- [ ] `scripts/encrypt-all.sh`
  - Find all files in `decrypted/`
  - Encrypt each to `encrypted/` (same structure)
  - Show summary of encrypted files

- [ ] `scripts/decrypt-all.sh`
  - Find all `.age` files in `encrypted/`
  - Decrypt each to `decrypted/` (remove .age extension)
  - Show summary of decrypted files

- [ ] `scripts/verify-integrity.sh`
  - Test all `.age` files can be decrypted
  - Report any corruption

- [ ] `scripts/rotate-key.sh`
  - Re-encrypt all files with new key
  - For key rotation scenarios

### Phase 3: Documentation (Day 2)

- [ ] Create `README.md` with:
  - Setup instructions
  - Usage workflow
  - Key backup strategy
  - Recovery procedures
  - Examples

- [ ] Document in host README:
  - Link to secrets management
  - Quick start guide

### Phase 4: Migration (Day 3-4)

- [ ] Identify current secrets to migrate
  - [ ] Search for `.env` files: `find ~ -name ".env*" -not -path "*/node_modules/*"`
  - [ ] Check for API keys in files
  - [ ] Review existing sensitive data

- [ ] Test encryption/decryption workflow
  - [ ] Create test file in `decrypted/`
  - [ ] Encrypt with script
  - [ ] Verify encrypted file
  - [ ] Decrypt and compare
  - [ ] Delete test files

- [ ] Migrate actual secrets
  - [ ] Copy sensitive files to `decrypted/`
  - [ ] Encrypt with `./scripts/encrypt-all.sh`
  - [ ] Verify decryption works
  - [ ] Delete original unencrypted copies (outside Secrets/)

- [ ] Initialize git repo

  ```bash
  cd ~/Secrets
  git init
  git add encrypted/ scripts/ .gitignore README.md keys.txt
  git commit -m "Initial secrets setup"

  # Add remote (private repo!)
  git remote add origin git@github.com:markus-barta/secrets.git
  git push -u origin main
  ```

### Phase 5: Testing (Day 4-5)

- [ ] Test full workflow on iMac
  - [ ] Edit decrypted file
  - [ ] Encrypt
  - [ ] Commit and push
  - [ ] Delete decrypted/
  - [ ] Git pull
  - [ ] Decrypt
  - [ ] Verify file content

- [ ] Test recovery scenario
  - [ ] Delete `decrypted/` completely
  - [ ] Decrypt from `encrypted/`
  - [ ] Verify all files restored

- [ ] Test on second machine (if available)
  - [ ] Clone repo
  - [ ] Decrypt secrets
  - [ ] Verify access to secrets

### Phase 6: Integration (Ongoing)

- [ ] Update application configs to read from `~/Secrets/decrypted/`
  - [ ] Update `.env` file references
  - [ ] Update SSH config (if using backed up keys)
  - [ ] Update API key references

- [ ] Document usage in project READMEs
  - [ ] How to decrypt secrets for project
  - [ ] What secrets are needed

---

## Security Considerations

### Key Backup Strategy

- [ ] Document where SSH key is backed up (if using SSH key approach)
- [ ] If using dedicated age key:
  - [ ] Print key to paper and store physically
  - [ ] Store encrypted backup of key (password-protected)
  - [ ] Document key location for recovery

### Access Control

- [ ] Keep private git repository
- [ ] Limit who has access to repo
- [ ] Consider separate repos for personal vs work
- [ ] Document who has access

### Rotation Plan

- [ ] Document key rotation procedure
- [ ] Schedule periodic review (every 6-12 months?)
- [ ] Test `rotate-key.sh` script before needed

### Monitoring

- [ ] Check git repo isn't public
- [ ] Verify `.gitignore` is working:
  ```bash
  git status  # Should NOT show decrypted/
  ```
- [ ] Periodic integrity check:
  ```bash
  ./scripts/verify-integrity.sh
  ```

---

## Questions / Decisions Needed

Before implementation, decide:

1. **Key Strategy**: [ ] SSH key or [ ] Dedicated age key?
2. **Workflow**: [ ] Manual or [ ] Auto-sync?
3. **Scope**: What specific secrets? (List them)
4. **Multi-machine**: [ ] Single repo with subdirs or [ ] Separate repos?
5. **Nix Integration**: [ ] Keep separate or [ ] Integrate with home-manager?
6. **Repository**: Create new private GitHub repo for secrets?

---

## Related Files

- Age encryption package: Currently in Homebrew, consider migrating to Nix
- home.nix: May need updates for secret paths
- Project configs: Update to reference `~/Secrets/decrypted/`

---

## Future Enhancements

- [ ] Add helper for generating new secrets
- [ ] Add script to check which secrets are older than X days
- [ ] Integration with password manager?
- [ ] Auto-backup of encrypted/ to external drive
- [ ] Pre-commit hook to prevent committing decrypted files
