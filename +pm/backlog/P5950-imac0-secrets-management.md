# P5950: imac0 Workstation Secrets Management

**Created**: 2025-12-01  
**Priority**: P6 (Medium-Low)  
**Effort**: 1-2 hours  
**Host**: imac0 (macOS)  
**Status**: Ready for Implementation  
**Documentation**: `docs/SECRETS.md`

---

## 🎯 What This Is

Age-based encryption for **personal secrets** on macOS workstations.

**Scope:**

- API keys (OpenAI, GitHub, etc.)
- Camera stream tokens (Tapo, Aqara)
- Personal environment variables
- Anything you need manually

**NOT for:**

- System services (use Tier 1: `secrets/` with agenix)
- Runbook docs (use Tier 2: `hosts/*/runbook-secrets.age`)

---

## 📋 Architecture

### Flat Structure

```
~/Secrets/
├── encrypted/          # ✅ Git-tracked (private repo)
│   ├── tapo-c210-living-room.age
│   ├── openai-api-key.age
│   └── github-token.age
├── decrypted/          # ❌ Gitignored
└── scripts/
    ├── encrypt.sh
    ├── decrypt.sh
    └── list.sh
```

**Why flat?** 5-10 secrets total. No need for subfolders.

### Manual Setup (5 minutes)

```bash
mkdir -p ~/Secrets/{encrypted,decrypted,scripts}
cat > ~/Secrets/.gitignore << 'EOF'
decrypted/
!decrypted/.gitkeep
.keys/
EOF
touch ~/Secrets/decrypted/.gitkeep

# Create scripts (see docs/SECRETS.md)
# Important: Set your age public key in encrypt.sh:
#   AGE_PUBLIC_KEY=$(age-keygen -y ~/.ssh/id_rsa)
chmod +x ~/Secrets/scripts/*.sh

cd ~/Secrets && git init && git add . && git commit -m "Initial"

# Configure git remote (configurable)
export SECRETS_REPO="encrypted-secrets"  # Your choice
export SECRETS_USER="markus-barta"       # Your GitHub username

# Option A: SSH (recommended)
git remote add origin git@github.com:${SECRETS_USER}/${SECRETS_REPO}.git

# Option B: HTTPS
# git remote add origin https://github.com/${SECRETS_USER}/${SECRETS_REPO}.git

# Push initial commit
git push -u origin main
```

---

## 🔒 Security Model

### Key Management

- **Encryption Key**: `~/.ssh/id_rsa` (existing SSH key)
- **Age Public Key**: Required for encrypting (`age-keygen -y ~/.ssh/id_rsa`)
- **Why**: No new keys, already backed up in 1Password
- **Risk**: SSH key compromise = secrets compromise
- **Mitigation**: SSH key has passphrase, already secured

**Note**: The `encrypt.sh` script needs your age public key. Get it with:

```bash
age-keygen -y ~/.ssh/id_rsa
```

### Access Control

| Who                 | Can Access                                      |
| ------------------- | ----------------------------------------------- |
| **You (Markus)**    | All secrets (has SSH key)                       |
| **Family members**  | Their personal secrets only (separate SSH keys) |
| **System services** | ❌ Cannot access (manual only)                  |

### Git Safety

| What               | Status                          |
| ------------------ | ------------------------------- |
| `encrypted/*.age`  | ✅ Committed (safe)             |
| `decrypted/`       | ❌ Gitignored (never committed) |
| Plain text secrets | ❌ Never in repo                |

### Threat Model

| Attacker       | Access       | Gets Secrets?             | Mitigation                  |
| -------------- | ------------ | ------------------------- | --------------------------- |
| Local malware  | Your account | ✅ Yes                    | SSH passphrase, `chmod 600` |
| Remote breach  | Server       | ✅ Yes (that server only) | Server hardening            |
| Git breach     | Repo         | ❌ No                     | Encrypted only              |
| Physical theft | Device       | ✅ Yes                    | FileVault, SSH passphrase   |

---

## 🎯 Usage Pattern

### Decrypt and Keep

```bash
cd ~/Secrets
./decrypt.sh tapo-c210-living-room
# File stays decrypted for scripts to use
```

**Security requirement:**

```bash
chmod 600 ~/Secrets/decrypted/tapo-c210-living-room
```

**Sidenote**: If you want to delete later, just `rm ~/Secrets/decrypted/<name>`

---

## 🚀 Commands

### Direct Scripts

```bash
cd ~/Secrets
./decrypt.sh tapo-c210-living-room
./encrypt.sh tapo-c210-living-room
./list.sh
```

### Just Commands (from justfile)

```bash
just private-decrypt tapo-c210-living-room
just private-encrypt tapo-c210-living-room
just private-encrypt-all
just private-decrypt-all
just private-list
just private-encrypt-commit      # Encrypt, commit, push
just private-pull-decrypt        # Pull, decrypt
```

---

## 📊 Implementation Steps

### Phase 1: Setup (5 min)

```bash
mkdir -p ~/Secrets/{encrypted,decrypted,scripts}
# Create .gitignore
cat > ~/Secrets/.gitignore << 'EOF'
decrypted/
!decrypted/.gitkeep
.keys/
EOF
touch ~/Secrets/decrypted/.gitkeep
# Create scripts (docs/SECRETS.md)
chmod +x ~/Secrets/scripts/*.sh
cd ~/Secrets && git init && git add . && git commit -m "Initial"
```

### Phase 2: Test (10 min)

```bash
cd ~/Secrets
echo "stream_token=test123" > decrypted/tapo-test
./encrypt.sh tapo-test
./decrypt.sh tapo-test
cat decrypted/tapo-test
# File stays decrypted for scripts
```

### Phase 3: Migrate (30-60 min)

```bash
# Move existing secrets
echo "stream_token=abc123..." > decrypted/tapo-c210-living-room
./encrypt.sh tapo-c210-living-room
# Decide: delete or keep?
```

**Total**: 1-2 hours

---

## ✅ Acceptance Criteria

- [ ] `~/Secrets/` directory created
- [ ] `.gitignore` configured
- [ ] Scripts created and executable (with age public key)
- [ ] Git repo initialized with configurable remote
- [ ] Camera token tested
- [ ] Just commands work (`private-*` prefix)
- [ ] Git sync commands work (`private-encrypt-commit`, `private-pull-decrypt`)
- [ ] Documentation complete (`docs/SECRETS.md`)
- [ ] Decision tree and cheat sheet added to docs
- [ ] All commands use `private-*` prefix for clarity

---

## 📚 Related

- **Main Guide**: `docs/SECRETS.md` (everything)
- **Just Commands**: `justfile` (workstation-secrets group)
- **Tier 1**: `secrets/` (system, agenix)
- **Tier 2**: `hosts/*/runbook-secrets.age` (docs)

---

## 🎯 Summary

**What you get:**

- ✅ Flat structure (simple)
- ✅ Manual setup (transparent)
- ✅ Camera examples (real-world)
- ✅ Single pattern (decrypt and keep)
- ✅ Security model (thorough)
- ✅ Git sync commands (private-encrypt-commit/private-pull-decrypt)
- ✅ Configurable git repo (SSH + HTTPS)
- ✅ Clear tier separation (private-\* prefix)

**Security guarantees:**

- Encrypted with SSH key (passphrase protected)
- Decrypted files never committed
- Manual control = intent-based security
- Flat structure = easy audit
- Configurable remote repo

**Ready to implement.**
