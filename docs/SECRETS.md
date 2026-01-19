# 🔐 Complete Secrets Management Guide

**Last Updated**: 2026-01-07  
**For**: All hosts (NixOS servers, macOS workstations, family computers)

---

## 🎯 Where Do I Put My Secret?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  DECISION TREE: Which Tier?                                                 │
│                                                                             │
│  Q1: Is it for a system service (NixOS server)?                             │
│      YES → Use Tier 1: secrets/ (agenix, automatic)                         │
│            Commands: just edit-secret, just rekey                           │
│      NO  → Continue...                                                      │
│                                                                             │
│  Q2: Is it for emergency documentation (runbook)?                           │
│      YES → Use Tier 2: hosts/*/runbook-secrets.age (manual)                 │
│            Commands: just decrypt-runbook-secrets <host>                    │
│      NO  → Continue...                                                      │
│                                                                             │
│  Q3: Is it for your personal use (macOS/Linux workstation)?                 │
│      YES → Use Tier 3: ~/Secrets/ (manual, age)                             │
│            Commands: just private-decrypt <name>                            │
│      NO  → Don't use this system                                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📖 Table of Contents

### Quick Start

- [How Do I Start?](#how-do-i-start) - Choose your user type
- [First Time Setup](#first-time-setup) - One-time configuration
- [Daily Usage](#daily-usage) - What you'll do every day

### By User Type

- [For Non-Technical Users (Family)](#for-non-technical-users-family) - 3 commands only
- [For Technical Users (You)](#for-technical-users-you) - Full just integration
- [For Sysops (Infrastructure)](#for-sysops-infrastructure) - All three tiers

### By Secret Type

- [Camera Stream Tokens](#camera-stream-tokens) - Real-world example
- [API Keys](#api-keys) - Development credentials
- [System Secrets](#system-secrets) - NixOS services

### Reference

- [Architecture Overview](#architecture-overview) - How it all works
- [Just Commands](#just-commands) - All available commands
- [Troubleshooting](#troubleshooting) - Common problems
- [Security Model](#security-model) - How it stays safe

---

## 📋 Quick Reference: All 3 Tiers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  TIER 1: System Secrets (NixOS servers)                                     │
│  Location: secrets/                                                         │
│  Tool: agenix (automatic decryption at boot)                                │
│  Commands: just edit-secret secrets/foo.age, just rekey                     │
│  Use for: MQTT credentials, API keys for services, system passwords         │
│                                                                             │
│  ⚠️ DANGER: The Rekeying Protocol                                           │
│  Global rekeys can SILENTLY WIPE secrets if your SSH key is missing.        │
│  1. Check file sizes: `ls -l secrets/*.age`                                 │
│  2. Look for "578 bytes" (corrupted/empty header only)                      │
│  3. Verify with `git diff --stat` BEFORE committing                         │
│                                                                             │
│  TIER 2: Runbook Secrets (all hosts)                                        │
│  Location: hosts/<host>/runbook-secrets.age                                 │
│  Tool: age (manual decryption)                                              │
│  Commands: just decrypt-runbook-secrets <host>                              │
│  Use for: Emergency docs, 1Password refs, network info                      │
│                                                                             │
│  TIER 3: Private Secrets (workstations)                                     │
│  Location: ~/Secrets/                                                       │
│  Tool: age (manual decryption)                                              │
│  Commands: just private-decrypt <name>, just private-encrypt-commit         │
│  Use for: Camera tokens, personal API keys, env vars                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🎯 How Do I Start?

### I'm a family member (wife, dad, etc.)

→ Jump to: [For Non-Technical Users](#for-non-technical-users-family)

### I'm Markus (technical user)

→ Jump to: [For Technical Users](#for-technical-users-you)

### I manage servers

→ Jump to: [For Sysops](#for-sysops-infrastructure)

### I just want to see examples

→ Jump to: [Camera Stream Tokens](#camera-stream-tokens)

---

## 🚀 First Time Setup

### For Non-Technical Users (Family)

**One-time setup:**

```bash
# 1. Create directory structure
mkdir -p ~/Secrets/{encrypted,decrypted,scripts}

# 2. Create .gitignore
cat > ~/Secrets/.gitignore << 'EOF'
decrypted/
!decrypted/.gitkeep
.keys/
EOF

# 3. Create .gitkeep
touch ~/Secrets/decrypted/.gitkeep

# 4. Initialize git
cd ~/Secrets
git init
git add .
git commit -m "Initial secrets setup"

# 5. Create scripts (see below)
# 6. Make scripts executable
chmod +x ~/Secrets/scripts/*.sh
```

**Create these three scripts in `~/Secrets/scripts/`:**

**`encrypt.sh`** - Encrypts a file:

```bash
#!/bin/bash
set -e

# Get your age public key: age-keygen -y ~/.ssh/id_rsa
# Example: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
AGE_PUBLIC_KEY="YOUR_AGE_PUBLIC_KEY_HERE"

if [ "$1" = "--all" ]; then
  for file in decrypted/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    age -r "$AGE_PUBLIC_KEY" encrypted/"$name".age decrypted/"$name"
    echo "Encrypted: $name"
  done
else
  age -r "$AGE_PUBLIC_KEY" encrypted/"$1".age decrypted/"$1"
  echo "Encrypted: $1"
fi
```

**Important**: Replace `YOUR_AGE_PUBLIC_KEY_HERE` with your age public key:

```bash
age-keygen -y ~/.ssh/id_rsa
```

**`decrypt.sh`** - Decrypts a file:

```bash
#!/bin/bash
set -e

if [ "$1" = "--all" ]; then
  for file in encrypted/*.age; do
    [ -f "$file" ] || continue
    name=$(basename "$file" .age)
    age -d -i ~/.ssh/id_rsa -o decrypted/"$name" "$file"
    echo "Decrypted: $name"
  done
else
  age -d -i ~/.ssh/id_rsa -o decrypted/"$1" encrypted/"$1".age
  echo "Decrypted: $1"
fi
```

**`list.sh`** - Shows status:

```bash
#!/bin/bash
echo "=== Encrypted Secrets ==="
ls -1 encrypted/ 2>/dev/null || echo "(none)"
echo ""
echo "=== Decrypted Secrets ==="
ls -1 decrypted/ 2>/dev/null | grep -v .gitkeep || echo "(none)"
```

**What you get:**

- `~/Secrets/` folder with all your secrets
- Simple scripts to encrypt/decrypt
- Everything ready to use
- Takes about 2 minutes

---

### For Technical Users (You)

**Same setup, plus just integration:**

```bash
# 1. Run manual setup (same as above)
mkdir -p ~/Secrets/{encrypted,decrypted,scripts}
# ... create .gitignore, scripts, etc.

# 2. Add just commands (already done in justfile)
# Just works automatically

# 3. Create private git repo (configurable)
cd ~/Secrets

# Set your configuration
export SECRETS_REPO="encrypted-secrets"  # Your choice
export SECRETS_USER="markus-barta"       # Your GitHub username

# Option A: SSH (recommended)
git remote add origin git@github.com:${SECRETS_USER}/${SECRETS_REPO}.git

# Option B: HTTPS
# git remote add origin https://github.com/${SECRETS_USER}/${SECRETS_REPO}.git

# Push initial commit
git push -u origin main
```

**Git sync commands:**

```bash
# Encrypt, commit and push all private secrets
just private-encrypt-commit

# Pull and decrypt all private secrets
just private-pull-decrypt
```

---

## 📅 Daily Usage

### Camera Stream Token Example (Real-World)

**Scenario**: You have a Tapo C210 camera at 192.168.1.50

**The secret file** (`~/Secrets/encrypted/tapo-c210-living-room.age`):

```
stream_token=abc123def456...
```

#### Decrypt and Use

```bash
# 1. Decrypt
cd ~/Secrets
./decrypt.sh tapo-c210-living-room

# 2. File stays decrypted (gitignored)
# Your script can now use it forever

# 3. Example script (~/bin/monitor-cameras.sh):
#!/bin/bash
source ~/Secrets/decrypted/tapo-c210-living-room
ffmpeg -i "rtsp://admin:${stream_token}@192.168.1.50:554/stream1" ...
```

**Important**: Set proper permissions:

```bash
chmod 600 ~/Secrets/decrypted/tapo-c210-living-room
```

**Note**: If you want to delete the decrypted file later in case of temporary use, just `rm ~/Secrets/decrypted/tapo-c210-living-room`. The age file will always be in the git repository.

---

### API Key Example (Development)

**Scenario**: You need OpenAI API key for a project

```bash
cd ~/Secrets
./decrypt.sh openai-api-key
# Keep it, your dev tools read it directly
```

---

## 👥 For Non-Technical Users (Family)

### What You Need to Know

**Only 3 commands:**

```bash
cd ~/Secrets

# Use a secret
./decrypt.sh tapo-c210-living-room

# Save a secret (after editing)
./encrypt.sh tapo-c210-living-room

# Check what you have
./list.sh
```

### Example: Dad's Camera Setup

```bash
# Decrypt camera token
cd ~/Secrets
./decrypt.sh tapo-c210-living-room

# Now his monitoring script works forever
# File stays at ~/Secrets/decrypted/tapo-c210-living-room
# It's gitignored, so safe from commits
```

**Sidenote**: If you want to delete the decrypted file later, just `rm ~/Secrets/decrypted/tapo-c210-living-room`

---

## 💻 For Technical Users (You)

### Just Commands (Recommended)

```bash
# Decrypt a private secret
just private-decrypt tapo-c210-living-room

# Encrypt a private secret
just private-encrypt tapo-c210-living-room

# All at once
just private-encrypt-all
just private-decrypt-all

# Check status
just private-list
```

### Direct Scripts (Alternative)

```bash
cd ~/Secrets
./decrypt.sh tapo-c210-living-room
./encrypt.sh tapo-c210-living-room
./list.sh
```

### Usage

```bash
# Decrypt a private secret
just private-decrypt tapo-c210-living-room

# Encrypt a private secret
just private-encrypt tapo-c210-living-room

# All at once
just private-encrypt-all
just private-decrypt-all
```

---

## 🖥️ For Sysops (Infrastructure)

### Three Tiers of Secrets

| Tier  | What            | Where                         | Tool   | Commands                            |
| ----- | --------------- | ----------------------------- | ------ | ----------------------------------- |
| **1** | System services | `secrets/`                    | agenix | `just edit-secret secrets/foo.age`  |
| **2** | Runbook docs    | `hosts/*/runbook-secrets.age` | age    | `just decrypt-runbook-secrets hsb0` |
| **3** | Private secrets | `~/Secrets/`                  | age    | `just private-decrypt tapo-c210`    |

### All Available Commands

```bash
# Tier 1: NixOS system secrets
just edit-secret secrets/mqtt-hsb0.age
just rekey
just keyscan

# Tier 2: Runbook documentation
just encrypt-runbook-secrets [host]
just decrypt-runbook-secrets [host]
just list-runbook-secrets

# Tier 3: Private secrets
just private-decrypt tapo-c210-living-room
just private-encrypt tapo-c210-living-room
just private-encrypt-all
just private-decrypt-all
just private-list

# See all secret commands
just --list | grep secret
```

---

## 🏗️ Architecture Overview

### The 3-Tier Model

```
TIER 1: NixOS System Secrets (agenix)
├── Location: secrets/
├── Auto-decrypt at boot
├── For: System services, Docker
└── Example: MQTT credentials, DHCP leases

TIER 2: Runbook Secrets (age)
├── Location: hosts/<host>/runbook-secrets.age
├── Manual decrypt
├── For: Emergency documentation
└── Example: 1Password references, network info

TIER 3: Private Secrets (age)
├── Location: ~/Secrets/
├── Manual decrypt
├── For: Personal API keys, camera tokens
└── Example: stream_token=abc123...
```

### Why Three Tiers?

**Tier 1**: Automatic, system-level, NixOS only  
**Tier 2**: Manual, documentation, all hosts  
**Tier 3**: Manual, personal, macOS/Linux

**Each tier has different:**

- Security requirements
- Automation level
- User audience

---

## 🎯 Real-World Examples

### Camera Streaming (Tier 3)

**File**: `~/Secrets/encrypted/tapo-c210-living-room.age`  
**Content**: `stream_token=abc123def456...`  
**Use**: Local monitoring script

```bash
# Setup
cd ~/Secrets
./decrypt.sh tapo-c210-living-room

# Script usage
source ~/Secrets/decrypted/tapo-c210-living-room
ffmpeg -i "rtsp://admin:${stream_token}@192.168.1.50:554/stream1" ...
```

### MQTT Credentials (Tier 1)

**Two patterns exist for different use cases:**

#### Pattern 1: MQTT Client Credentials (Standardized)

**Files**: `secrets/mqtt-hsb0.age`, `secrets/mqtt-csb0.age`  
**Content**: `MQTT_HOST=localhost\nMQTT_USER=smarthome\nMQTT_PASS=secret`  
**Use**: MQTT client services (Node-RED, UPS monitoring, etc.)  
**Format**: Environment variables for service configuration

```nix
# Example: UPS MQTT publishing service
age.secrets.mqtt-hsb0 = {
  file = ../../secrets/mqtt-hsb0.age;
  mode = "400";
  owner = "root";
};

systemd.services.ups-mqtt.serviceConfig.EnvironmentFile =
  config.age.secrets.mqtt-hsb0.path;
```

#### Pattern 2: Mosquitto Broker Configuration (Legacy but Functional)

**Files**: `secrets/mosquitto-conf.age`, `secrets/mosquitto-passwd.age`  
**Content**:

- `mosquitto-conf.age`: Mosquitto configuration file (mosquitto.conf format)
- `mosquitto-passwd.age`: Mosquitto password file (password_file format)  
  **Use**: Mosquitto broker Docker service configuration  
  **Format**: Direct configuration files mounted as Docker volumes

```nix
# Example: Mosquitto broker configuration
age.secrets.mosquitto-conf = {
  file = ../../secrets/mosquitto-conf.age;
  mode = "644";
  owner = "1883";  # mosquitto user
  group = "1883";
};

age.secrets.mosquitto-passwd = {
  file = ../../secrets/mosquitto-passwd.age;
  mode = "644";
  owner = "1883";
  group = "1883";
};
```

**Key Difference:**

- **Client credentials** (`mqtt-*.age`): Used by services connecting TO the broker
- **Broker configuration** (`mosquitto-*.age`): Used BY the broker itself for operation

Both patterns are valid and serve complementary purposes in the MQTT infrastructure.

### Emergency Access (Tier 2)

**File**: `hosts/hsb8/runbook-secrets.age`  
**Content**: Markdown with 1Password references  
**Use**: Emergency server recovery

```bash
just decrypt-runbook-secrets hsb8
# Shows: "Admin password: See 1Password 'hsb8 Root'"
```

---

## 🔒 Security Model

### Key Management

**All tiers use your SSH key** (`~/.ssh/id_rsa`):

- No new keys to manage
- Already backed up in 1Password
- Same key for agenix and age

### Access Control

| Who                 | Can Access                      |
| ------------------- | ------------------------------- |
| **You (Markus)**    | All secrets (has all keys)      |
| **gb (on hsb8)**    | hsb8 runbook + personal secrets |
| **Family members**  | Their personal secrets only     |
| **System services** | Tier 1 secrets only (automatic) |

### Git Safety

**What gets committed:**

- ✅ `secrets/*.age` (encrypted)
- ✅ `hosts/*/runbook-secrets.age` (encrypted)
- ✅ `~/Secrets/encrypted/` (encrypted)

**What never gets committed:**

- ❌ `~/Secrets/decrypted/` (gitignored)
- ❌ Plain text secrets anywhere

### Threat Model

| Attacker           | Access        | Can Get Secrets?          | Mitigation                        |
| ------------------ | ------------- | ------------------------- | --------------------------------- |
| **Local malware**  | Your account  | ✅ Yes                    | SSH passphrase, file permissions  |
| **Remote breach**  | Server access | ✅ Yes (that server only) | Server hardening                  |
| **Git breach**     | Repo access   | ❌ No                     | Encrypted only                    |
| **Physical theft** | Stolen device | ✅ Yes                    | FileVault, SSH passphrase         |
| **Misconfig**      | **YOU**       | 🔴 **DATA LOSS**          | **Verify file sizes after rekey** |

---

## ⚙️ Just Commands Reference

### All Secret Commands

```bash
# Tier 1: NixOS (agenix)
just edit-secret secrets/NAME.age
just rekey
just keyscan

# Tier 2: Runbook docs
just encrypt-runbook-secrets [host]
just decrypt-runbook-secrets [host]
just list-runbook-secrets

# Tier 3: Private secrets
just private-decrypt tapo-c210-living-room
just private-encrypt tapo-c210-living-room
just private-encrypt-all
just private-decrypt-all
just private-list
just private-encrypt-commit      # Encrypt, commit, push
just private-pull-decrypt        # Pull, decrypt
```

### Quick Reference

```bash
# What private secrets do I have?
just private-list

# Decrypt a camera token
just private-decrypt tapo-c210-living-room

# Encrypt it back
just private-encrypt tapo-c210-living-room

# Everything at once
just private-encrypt-all
just private-decrypt-all

# Sync with git
just private-encrypt-commit
just private-pull-decrypt
```

---

## 🆘 Troubleshooting

### 🚨 EMERGENCY: Secrets were wiped (578 bytes)

If you ran `just rekey` and your secrets suddenly dropped to ~578 bytes:

1. **STOP**: Do not commit or push.
2. **RESTORE**: `git reset --hard HEAD` (or `HEAD~1` if already committed).
3. **DEBUG**: Ensure your SSH key is added to the agent (`ssh-add ~/.ssh/id_rsa`).
4. **RETRY**: Try decrypting one file first: `agenix -d secrets/foo.age`.

### "Command not found"

```bash
# Not in right directory
cd ~/Secrets
./decrypt.sh tapo-c210-living-room

# Or use just
just private-decrypt tapo-c210-living-room
```

### "Permission denied"

```bash
# Make scripts executable
chmod +x ~/Secrets/scripts/*.sh
```

### "age: command not found"

```bash
# Install age
# macOS:
brew install age

# Or add to home.nix:
home.packages = with pkgs; [ age ];
```

### "File not found"

```bash
# Did you run manual setup first?
# See: First Time Setup section above

# Check if it exists
ls ~/Secrets/encrypted/
```

### "I forgot what I decrypted"

```bash
cd ~/Secrets
./list.sh
# Shows decrypted files
```

### "I want to use just but it doesn't work"

```bash
# Check if just is installed
which just

# See all secret commands
just --list | grep secret
```

---

## 📋 Decision Guide

### "Which tier do I use?"

**For personal secrets on your Mac:**

- Tier 3: `~/Secrets/`

**For server system secrets:**

- Tier 1: `secrets/`

**For emergency documentation:**

- Tier 2: `hosts/*/runbook-secrets.age`

### "Which command should I use?"

**If you use just:**

```bash
just private-decrypt tapo-c210-living-room
```

**If you prefer direct scripts:**

```bash
cd ~/Secrets
./decrypt.sh tapo-c210-living-room
```

**Both work the same.** Use what feels natural.

---

## 🎯 Summary

### For Non-Technical Users

**Remember 3 commands:**

```bash
cd ~/Secrets
./decrypt.sh <path>
./encrypt.sh <path>
```

**Delete vs Keep:**

- Delete: One-time use
- Keep: Script needs it

### For Technical Users

**Use just commands:**

```bash
just private-decrypt <name>
just private-encrypt <name>
just private-list
```

### For Sysops

**All three tiers:**

```bash
# System secrets
just edit-secret secrets/foo.age

# Runbook docs
just decrypt-runbook-secrets hsb0

# Private secrets
just private-decrypt tapo-c210
```

---

## 📚 Related Files

- `+pm/backlog/P5950-imac0-secrets-management.md` - Implementation plan
- `justfile` - All just commands
- `secrets/secrets.nix` - Tier 1 key definitions
- `secrets/NAMING-PATTERN.md` - Naming standards and migration guide
- `scripts/runbook-secrets.sh` - Tier 2 tooling

---

## 🔄 Update History

- **2026-01-07**: Simplified to single pattern, added git sync commands
- **2025-12-01**: Initial workstation secrets planning (P5950)
