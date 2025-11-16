# PICK UP HERE - Secrets Management Migration

**Date**: 2025-11-15  
**Status**: 🟡 Planning Phase - Ready to Review 1Password  
**Last Activity**: Created comprehensive migration plan

---

## 🎯 **CURRENT TASK**

**You need to**: Review 1Password and document all server credentials

**What to do**:

1. Open 1Password
2. Go through each server entry (csb0, csb1, miniserver24, miniserver99, msww87)
3. Fill in the checklist in `docs/secrets-migration-plan.md`
4. Test SSH access to each server
5. Report back what you found

**Document to use**: `/Users/markus/Code/nixcfg/docs/secrets-migration-plan.md`

---

## 📚 **CONTEXT: What We Did Today**

### **1. Completed Homebrew Migration** ✅

**Achievement**: 100% migration from Homebrew to Nix on `imac-mba-home`

**Key accomplishments**:

- Migrated 25 CLI tools to Nix (gh, jq, just, lazygit, tree, pv, zellij, etc.)
- Removed 42 Homebrew packages
- Freed ~700MB disk space
- Configured nano with modern version and syntax highlighting
- Fixed Nerd Fonts in WezTerm (Starship rendering works)
- Documented Karabiner-Elements hybrid approach (app in Homebrew, config in Nix)
- Created manual setup docs for Terminal.app Nerd Fonts

**Current state**:

- ✅ Fish shell from Nix (`/Users/markus/.nix-profile/bin/fish`)
- ✅ Node.js v22.20.0 from Nix
- ✅ Python 3 from Nix
- ✅ All CLI tools from Nix
- ✅ `gh` (GitHub CLI) works and is from Nix
- ⚠️ Some GUI apps still in Homebrew (mactex-no-gui, git for system integration)

**Remaining Homebrew** (intentionally kept):

- Git (for macOS system integration)
- MacTeX (TeX distribution)
- Karabiner-Elements (keyboard remapping)
- WezTerm (via Homebrew Cask)
- evernote-backup (not in nixpkgs)

### **2. Repository Made Private** ✅

**Action**: Changed nixcfg GitHub repo to private using `gh` CLI

**Command used**:

```bash
gh repo edit markus-barta/nixcfg --visibility private --accept-visibility-change-consequences
```

**Verified**: Repository is now `PRIVATE`

**Why**: To safely store encrypted secrets and infrastructure details

### **3. Documented Complete Infrastructure** ✅

**DNS Documentation** (`docs/dns-barta-cm.md`):

- Complete DNS record inventory (5 A records, 8 CNAME records)
- Service-to-server mapping (csb0: 5 services, csb1: 6 services)
- Cloudflare proxy status for each subdomain
- Future Terraform/OpenTofu migration plan

**Host Documentation**:

- `hosts/README.md` - Ownership, naming conventions, all 7+ machines
- `hosts/csb0/README.md` - Cloud server details, services, access info
- `hosts/csb1/README.md` - Cloud server details, services, access info

**Discovered Services**:

**csb0** (85.235.65.226):

- node-RED (home.barta.cm)
- Mosquitto MQTT (mosquitto.barta.cm)
- Telegram Bot (t.me/csb0bot)
- Bitwarden (bitwarden.barta.cm)
- Traefik (traefik.barta.cm)
- WhoAmI test service (whoami0.barta.cm)

**csb1** (152.53.64.166):

- Grafana (grafana.barta.cm) - 5 users: caroline, otto, gerhard, markus, mailina
- InfluxDB3 (influxdb.barta.cm)
- Hedgedoc (hdoc.barta.cm)
- Docmost (docmost.barta.cm) - Cloudflare proxied
- Paperless-ngx (paperless.barta.cm) - Cloudflare proxied
- WhoAmI test service (whoami1.barta.cm)

### **4. Analyzed Secrets Management** ✅

**Discovery**: Repository already uses `agenix` for NixOS secrets!

**Existing agenix usage**:

- ✅ Used by pbek's Linux systems (eris, neptun, pluto, etc.)
- ✅ Working pattern in `modules/hokage/desktop-minimum.nix`
- ✅ Secrets stored in `secrets/*.age` files
- ✅ Registry in `secrets/secrets.nix`
- ✅ Commands in `justfile` (encrypt-file, decrypt-file)

**Pattern found**:

- miniserver99: Manual encryption of `static-leases.nix`
- Linux desktops: Declarative `age.secrets` in NixOS config
- macOS: No agenix integration yet (this is what we're adding!)

**Decision**: Extend existing agenix instead of creating custom scripts

### **5. Identified Three Types of Secrets** ✅

**Type 1: Server Secrets** 🖥️

- **What**: Credentials services need to run
- **Examples**: MQTT passwords, database credentials, API tokens
- **Who uses**: The system itself (automated)
- **Where**: csb0, csb1, miniserver24, miniserver99, msww87

**Type 2: User Secrets** 👤

- **What**: Your personal credentials across all machines
- **Examples**: Git work identity, SSH keys, shell sync keys
- **Who uses**: You (your user account)
- **Where**: All your machines (imac-mba-home, work laptop, etc.)

**Type 3: Development Secrets** 💻

- **What**: API keys for specific coding projects
- **Examples**: OpenAI API key, GitHub token, AWS credentials
- **Who uses**: Your code projects
- **Where**: Only when developing specific projects

### **6. Verified SSH Key Backup** ✅

**Your primary SSH key**:

- Type: RSA 2048-bit
- Created: June 4, 2019
- Location: `~/.ssh/id_rsa`
- Fingerprint: `SHA256:5lA0y6bmhmqN56buekbRFwMpaE7vxiUTunWPnmXauNM`
- Backed up: ✅ YES in 1Password ("Private SSH Key - mba / markus / imac")
- Passphrase: None (or unlocked in ssh-agent)

**Security assessment**: RSA 2048 is **secure until ~2030**

**Decision**: Keep RSA 2048, don't upgrade now (would require 2-4 hours + risk)

**Future**: Consider ED25519 upgrade in 2026+

### **7. Discovered Secrets Landscape** ✅

**SSH keys found**:

- `~/.ssh/id_rsa` (personal, RSA, 2019)
- `~/.ssh/id_ed25519_bytepoets` (work, ED25519)
- `~/.ssh/github-actions-deploy` (CI/CD)
- `~/.ssh/lima_rsa` (Lima VMs)

**Git config**:

- Current identity: Markus Barta <markus@barta.com>
- Work email (to encrypt): markus.barta@bytepoets.com
- SSH config has work GitHub setup (`github-bp` → `id_ed25519_bytepoets`)

**.env files**:

- Only found: `~/Code/cloud-server/.env` (just project name, no secrets)
- No scattered development secrets found

**Existing agenix secrets**:

- ✅ `github-token.age` (already have)
- ✅ `atuin.age` (shell history sync)
- ✅ Others for pbek's systems

### **8. Created Planning Documents** ✅

**Three key documents created**:

1. **`docs/secrets-inventory.md`** (gitignored)
   - Comprehensive checklist of all secrets
   - Server-by-server breakdown
   - Based on 1Password entries and DNS discovery
   - Includes TODOs for verification

2. **`docs/secrets-migration-plan.md`** ⭐ **PRIMARY DOCUMENT**
   - Complete 6-phase migration plan
   - Detailed checklists for each server
   - Risk assessment and mitigations
   - Timeline estimate (3-5 hours)
   - Success criteria
   - Open questions to answer

3. **`hosts/imac-mba-home/docs/reference/secrets-management.md`**
   - Original design doc (custom scripts approach)
   - **SUPERSEDED** by simpler agenix approach
   - Kept for reference only

---

## 🎯 **THE PLAN: 6 Phases**

### **Phase 1: Planning** 🟡 **← YOU ARE HERE**

**Status**: In Progress  
**Next action**: Review 1Password and fill in checklists

**Tasks**:

- [ ] Review all server entries in 1Password
- [ ] Document credentials for csb0, csb1, miniserver24, miniserver99, msww87
- [ ] Test SSH access to each server
- [ ] Identify missing/unknown credentials
- [ ] Prioritize servers (HIGH/MEDIUM/LOW)

### **Phase 2: Design** ⬜

**Status**: Pending  
**Depends on**: Completing Phase 1

**Tasks**:

- Finalize `secrets/` directory structure
- Design encryption keys strategy (who can decrypt what)
- Plan file formats (.env, JSON, plain text)
- Design deployment approach per server

### **Phase 3: Setup Infrastructure** ⬜

**Status**: Pending

**Tasks**:

- Create `secrets/servers/` directory
- Create `secrets/user/` directory
- Update `secrets/secrets.nix` with new entries
- Test agenix commands work

### **Phase 4: Migrate** ⬜

**Status**: Pending

**Tasks**:

- Migrate ONE server first (pilot: csb0 or csb1)
- Test thoroughly
- Migrate remaining servers one by one
- Migrate user secrets (Git work identity)

### **Phase 5: Deploy** ⬜

**Status**: Pending

**Tasks**:

- Deploy encrypted secrets to servers
- Update NixOS configurations to use secrets
- Verify all services still work
- Test disaster recovery

### **Phase 6: Cleanup** ⬜

**Status**: Pending

**Tasks**:

- Mark secrets in 1Password as "Migrated"
- Keep 1Password as backup (don't delete!)
- Update all documentation
- Remove temporary planning docs

---

## 📊 **KEY DECISIONS MADE**

1. ✅ **Use existing agenix** (don't create custom scripts)
2. ✅ **Keep RSA 2048** (secure until 2030, upgrade later)
3. ✅ **Incremental migration** (one server at a time)
4. ✅ **Keep 1Password as backup** (during and after migration)
5. ✅ **Plan first, execute later** (proper preparation)
6. ✅ **Three secret types** (Server, User, Dev)
7. ✅ **Platform-aware approach**:
   - NixOS servers: Declarative `age.secrets` (like pbek's systems)
   - macOS: Manual rage decryption or home-manager
   - Dev secrets: Manual as needed

---

## 🗂️ **DIRECTORY STRUCTURE (PLANNED)**

```
~/Code/nixcfg/
├── secrets/
│   ├── secrets.nix              # SSH key registry (exists)
│   ├── github-token.age         # Dev secrets (exists)
│   ├── atuin.age               # User secrets (exists)
│   ├── static-leases-miniserver99.age  # Server (exists)
│   │
│   ├── servers/                # NEW: To be created
│   │   ├── csb0-nodered.age
│   │   ├── csb0-mqtt.age
│   │   ├── csb0-telegram-bot.age
│   │   ├── csb0-bitwarden.age
│   │   ├── csb0-traefik.age
│   │   ├── csb1-grafana-users.age
│   │   ├── csb1-influxdb.age
│   │   ├── csb1-hedgedoc.age
│   │   ├── miniserver24-mqtt.age
│   │   ├── miniserver24-tapo.age
│   │   └── miniserver99-adguard.age
│   │
│   └── user/                   # NEW: To be created
│       └── git-work-identity.age
│
├── docs/
│   ├── secrets-inventory.md    # Gitignored, temporary
│   ├── secrets-migration-plan.md  # Main planning doc
│   ├── dns-barta-cm.md         # DNS infrastructure
│   └── PICK-UP-HERE.md         # This file
│
└── hosts/
    ├── README.md               # All hosts overview
    ├── csb0/README.md          # Cloud server 0
    ├── csb1/README.md          # Cloud server 1
    ├── imac-mba-home/          # Your Mac
    ├── miniserver24/           # Local server
    ├── miniserver99/           # Local server
    └── msww87/                 # Remote home automation
```

---

## 📝 **IMPORTANT FILES**

### **Priority 1: Must Read**

1. **`docs/secrets-migration-plan.md`** - Complete migration plan, your main TODO
2. **`docs/secrets-inventory.md`** - Detailed inventory template (gitignored)

### **Priority 2: Reference**

3. **`hosts/README.md`** - Overview of all your machines
4. **`hosts/csb0/README.md`** - csb0 details and services
5. **`hosts/csb1/README.md`** - csb1 details and services
6. **`docs/dns-barta-cm.md`** - Complete DNS and service mapping

### **Priority 3: Background**

7. **`secrets/secrets.nix`** - SSH public key registry (how agenix knows who can decrypt)
8. **`modules/hokage/desktop-minimum.nix`** - Example of how pbek uses agenix
9. **`hosts/miniserver99/README.md`** - Example of current secrets pattern

---

## 🔑 **CRITICAL INFORMATION**

### **Your Machines**

| Machine         | Type         | Status    | Purpose                               |
| --------------- | ------------ | --------- | ------------------------------------- |
| `imac-mba-home` | macOS        | ✅ Active | Your primary workstation              |
| `csb0`          | NixOS Cloud  | ✅ Active | IoT & Home Automation (85.235.65.226) |
| `csb1`          | NixOS Cloud  | ✅ Active | Monitoring & Docs (152.53.64.166)     |
| `miniserver24`  | NixOS Local  | ✅ Active | Home automation (192.168.1.101)       |
| `miniserver99`  | NixOS Local  | ✅ Active | DNS/DHCP server (192.168.1.99)        |
| `msww87`        | NixOS Remote | ✅ Active | Father's home automation              |
| `gaming-pc-mba` | Dual-boot    | 🟡 Future | Windows + NixOS                       |

### **Server Access** (From Your Messages)

**csb1**:

- SSH: `ssh mba@cs1.barta.cm` or `qc1` (fish abbreviation)
- SSH password: `F0NyqFJD7rwmpct24c1`
- IP: 152.53.64.166
- FQDN: v2202407214994279426.bestsrv.de

**csb0**:

- SSH: `ssh mba@cs0.barta.cm`
- IP: 85.235.65.226

**miniserver24 & miniserver99**:

- Local network: 192.168.1.x
- SSH: Key-based (your id_rsa)

### **Work Email** (For Git Identity)

- Email: `markus.barta@bytepoets.com`
- SSH Key: `~/.ssh/id_ed25519_bytepoets`
- GitHub: `github-bp` (configured in `~/.ssh/config`)

---

## ⚠️ **THINGS TO REMEMBER**

### **Don't Do These (Yet)**

- ❌ Don't delete anything from 1Password
- ❌ Don't change any server configurations
- ❌ Don't deploy anything to production
- ❌ Don't upgrade SSH keys (RSA 2048 is fine)

### **Do These Now**

- ✅ Review 1Password thoroughly
- ✅ Test SSH access to all servers
- ✅ Document what you find
- ✅ Ask questions if unsure

### **gitignored Files** (Safe to have secrets temporarily)

- `docs/secrets-inventory.md` - Your working notes
- `dns-backup-*.json` - DNS exports
- `cloudflare-*.json` - API backups

---

## 🚀 **WHEN YOU COME BACK**

### **If You've Reviewed 1Password**

Say: "Done with 1Password review"

Then share:

1. What servers you found credentials for
2. What's missing
3. Which servers you can SSH into
4. Any questions or concerns

### **If You Haven't Started Yet**

Say: "Ready to start planning"

I'll guide you through:

1. Opening 1Password
2. Finding server entries
3. Testing SSH access
4. Filling in the checklists

### **If You Have Questions**

Just ask! Common questions:

- "Which server should I migrate first?"
- "What if I can't find X in 1Password?"
- "What if SSH doesn't work?"
- "Can you explain X again?"

---

## 📚 **BACKGROUND READING** (If Needed)

### **Understanding agenix**

- Repository already has it: `inputs.agenix.url = "github:ryantm/agenix"`
- Used by pbek's systems (eris, neptun, pluto)
- Works with SSH keys for encryption/decryption
- Files: `secrets/*.age` encrypted, plaintext never committed

### **How It Works**

1. You have SSH keys (`~/.ssh/id_rsa.pub`)
2. Servers have SSH host keys (auto-generated)
3. Secrets encrypted with those public keys
4. Only machines with private keys can decrypt
5. Stored in git as `.age` files (safe to commit)

### **Example Commands**

```bash
# Encrypt a secret (interactive editor)
cd ~/Code/nixcfg/secrets
agenix -e servers/csb0-mqtt.age

# Decrypt a secret (output to stdout)
agenix -d servers/csb0-mqtt.age

# Use justfile helper
just encrypt-file hosts/miniserver99/static-leases.nix
just decrypt-file secrets/static-leases-miniserver99.age
```

---

## 🎯 **SUCCESS CRITERIA**

You'll know you're done when:

- ✅ All server secrets encrypted in git
- ✅ All secrets can be decrypted and used
- ✅ All services running normally
- ✅ No plaintext secrets in repository
- ✅ Complete documentation
- ✅ Tested disaster recovery
- ✅ 1Password kept as backup

---

## 📞 **QUICK REFERENCE**

### **Your Email Addresses**

- Personal: markus@barta.com (current Git default)
- Work: markus.barta@bytepoets.com (need to encrypt for dual identity)

### **Your SSH Keys**

- Personal: `~/.ssh/id_rsa` (RSA 2048, backed up in 1Password)
- Work: `~/.ssh/id_ed25519_bytepoets` (ED25519)
- GitHub Actions: `~/.ssh/github-actions-deploy`

### **Key File Locations**

- Nix config: `~/Code/nixcfg/`
- Secrets: `~/Code/nixcfg/secrets/`
- Planning docs: `~/Code/nixcfg/docs/`
- This file: `~/Code/nixcfg/docs/PICK-UP-HERE.md`

---

## 💬 **WHAT TO SAY WHEN YOU RETURN**

### **Option 1: Ready to Continue Planning**

> "I've reviewed 1Password. Here's what I found..."

### **Option 2: Need Clarification**

> "Question about [topic]..."

### **Option 3: Ready to Execute**

> "Planning done, ready to start migrating"

### **Option 4: Taking Longer Break**

> "Will continue later, just checking in"

---

## 🏆 **WHAT WE'VE ACCOMPLISHED TODAY**

1. ✅ Completed Homebrew → Nix migration (100%)
2. ✅ Made repository private
3. ✅ Documented complete infrastructure (7 servers, 13+ services)
4. ✅ Analyzed secrets management options
5. ✅ Decided on agenix approach
6. ✅ Verified SSH key backup
7. ✅ Created comprehensive migration plan
8. ✅ Identified what needs to be done

**You're in great shape!** Just need to review 1Password and we can continue. 🎉

---

## 📅 **ESTIMATED TIMELINE**

| Phase              | Time          | When                   |
| ------------------ | ------------- | ---------------------- |
| Planning (current) | 1 hour        | Today/Tomorrow         |
| Design             | 15 min        | After planning         |
| Pilot migration    | 30 min        | When ready             |
| Full migration     | 2 hours       | Can spread over days   |
| Verification       | 30 min        | After migration        |
| Cleanup            | 15 min        | Final step             |
| **TOTAL**          | **4-5 hours** | Over 1-2 weeks is fine |

**No rush!** This can be done incrementally.

---

**Last Updated**: 2024-11-15  
**Next Step**: Review 1Password (use `docs/secrets-migration-plan.md` as checklist)  
**Status**: 🟢 All systems working, ready to proceed at your pace
