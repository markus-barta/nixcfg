# Secrets Management Architecture

**Status**: Approved - Awaiting Implementation  
**Last Updated**: 2025-11-15

---

## Overview

Automated, multi-machine secrets management using `rage` (age encryption) with SSH key-based encryption and directory watching for zero-friction workflow.

---

## Architecture Decisions

### Repository Structure

**Two separate private GitHub repositories**:

- `~/Secrets/personal/` - Personal secrets (all machines)
- `~/Secrets/work/` - Work secrets (work machines only)

**Rationale**: Security isolation, separate access control, cleaner permissions.

### Key Management Strategy

**SSH keys** (no dedicated age keys)

- Encryption: `rage -R ~/.ssh/id_rsa.pub -o file.age file.txt`
- Decryption: `rage -d -i ~/.ssh/id_rsa file.age > file.txt`

**Rationale**: No new keys to manage, SSH key already backed up in 1Password, works everywhere SSH key works.

### Automation Level

**Auto-stage** (not auto-commit)

- Watchman detects file changes in `decrypted/`
- Auto-encrypts to `encrypted/` within 1-2 seconds
- Auto-stages encrypted files in git
- User writes commit message and commits manually

**Rationale**: Balance automation with control. No noisy commit history, can batch changes, meaningful commit messages.

### Scripts Distribution

**Self-contained with canonical source**

- Canonical: `~/Code/nixcfg/.shared/secrets-scripts/`
- Deployed: Copied to each secrets repo `.secrets/scripts/`
- Update: `update-scripts.sh` syncs from canonical

**Rationale**: Each repo is independent (works without nixcfg), easy updates, versioned with repo, emergency-ready.

---

## Directory Structure

```
~/Secrets/personal/                    # Private GitHub repo
├── encrypted/                         # ✅ Git-tracked
│   ├── env/
│   ├── api-keys/
│   └── ssh-backup/
├── decrypted/                         # ❌ Gitignored
│   └── (same structure)
├── .secrets/
│   ├── scripts/                       # Management scripts
│   └── config.sh                      # Machine-specific config
├── .gitignore
├── .watchmanconfig
└── README.md
```

---

## Core Features

### 1. Automated Encryption

Watchman monitors `decrypted/` and auto-encrypts on save:

```bash
# Start watching (in tmux/zellij session)
./.secrets/scripts/watch.sh

# Edit file - auto-encrypted within 1-2 seconds
vim decrypted/env/api-key.env
# 🔒 Encrypting: env/api-key.env
# ✅ Staged: encrypted/env/api-key.env.age
```

### 2. Multi-Machine Sync

```bash
# Pull latest + decrypt
./.secrets/scripts/sync.sh

# Or manual
git pull
./.secrets/scripts/decrypt-all.sh
```

### 3. Safety Mechanisms

- Pre-commit hook prevents committing `decrypted/`
- Integrity verification: `./.secrets/scripts/verify.sh`
- Auto-backup before overwrite
- Git history check warns if plaintext ever committed

### 4. Selective Decryption

```bash
# Decrypt everything
./.secrets/scripts/decrypt-all.sh

# Decrypt single file (servers)
./.secrets/scripts/decrypt.sh encrypted/env/database.env.age
```

---

## Workflow

### Daily Usage

```bash
# 1. Edit secret (watchman auto-encrypts)
vim ~/Secrets/personal/decrypted/env/new-key.env
# ✅ Auto-staged: encrypted/env/new-key.env.age

# 2. Review and commit
cd ~/Secrets/personal
git status
git commit -m "Add new API key"
git push
```

### New Machine Setup

```bash
# Clone repo
git clone git@github.com:markus-barta/secrets-personal.git ~/Secrets/personal

# Decrypt all
cd ~/Secrets/personal
./.secrets/scripts/decrypt-all.sh

# Start watching
./.secrets/scripts/watch.sh &
```

---

## Security Model

### Encryption

- Uses your SSH public key for encryption
- Any machine with your SSH private key can decrypt
- No shared secrets, no team access complexity

### Git Repository

- Private repositories only
- Encrypted files tracked, decrypted files gitignored
- Pre-commit hooks prevent accidental leaks

### Key Backup

- SSH key already in 1Password
- Recovery: Restore SSH key → decrypt all secrets
- No additional backup strategy needed

---

## Multi-Machine Strategy

| Machine     | personal/ | work/   | Method                       |
| ----------- | --------- | ------- | ---------------------------- |
| Home iMac   | ✅ Full   | ❌ No   | Clone personal only          |
| Work Laptop | ✅ Full   | ✅ Full | Clone both repos             |
| Servers     | ✅ Select | ❌ No   | Clone, selective decryption  |
| Future Mac  | ✅ Full   | TBD     | Clone, copy SSH key, decrypt |

---

## Implementation Phases

1. **Canonical Scripts** - Create in `nixcfg/.shared/secrets-scripts/`
2. **Personal Repo** - Setup `~/Secrets/personal/` with GitHub repo
3. **Work Repo** - Setup `~/Secrets/work/` (optional, later)
4. **Migration** - Find and migrate existing secrets
5. **Deploy** - Setup on servers and work machines

---

## Scripts Manifest

| Script              | Purpose                        |
| ------------------- | ------------------------------ |
| `encrypt.sh`        | Encrypt single file            |
| `decrypt.sh`        | Decrypt single file            |
| `encrypt-all.sh`    | Bulk encrypt `decrypted/`      |
| `decrypt-all.sh`    | Bulk decrypt `encrypted/`      |
| `watch.sh`          | Start watchman auto-encryption |
| `sync.sh`           | Git pull + auto-decrypt        |
| `verify.sh`         | Integrity check all files      |
| `update-scripts.sh` | Sync from canonical source     |

---

## Dependencies

- `rage` or `age` (encryption tool)
- `watchman` (directory watcher)
- `git` (version control)
- SSH key pair (already have)

**Installation**:

```bash
# macOS (Homebrew)
brew install watchman

# Nix
# Add to home.packages: pkgs.rage, pkgs.watchman
```

---

## Comparison to Alternatives

| Approach          | This Solution    | Why Better                   |
| ----------------- | ---------------- | ---------------------------- |
| agenix            | Manual age + git | Simpler, no NixOS dependency |
| Password Manager  | Git + encryption | Version control, grep-able   |
| .env Files        | Encrypted .env   | Safe to commit               |
| Manual Encryption | Automated        | Zero friction, can't forget  |
| Single Repo       | Separate repos   | Better isolation             |

---

## References

- **Age Encryption**: <https://github.com/FiloSottile/age>
- **Rage** (Rust impl): <https://github.com/str4d/rage>
- **Watchman**: <https://facebook.github.io/watchman/>
- **Existing Pattern**: `miniserver99` static-leases encryption
