# Secrets Migration Plan

**Status**: 📋 Planning Phase  
**Started**: 2024-11-15  
**Goal**: Migrate all secrets from 1Password to agenix (encrypted in git)

---

## 🎯 **Migration Strategy**

### **Approach**: Incremental, Non-Disruptive

1. **Keep 1Password** as source of truth during migration
2. **Copy** secrets to agenix (don't delete from 1Password yet)
3. **Test** encrypted secrets work before deploying
4. **Deploy** one server at a time
5. **Verify** everything works
6. **Only then** clean up 1Password

---

## 📋 **Phase 1: Inventory & Planning** (CURRENT)

### **Task 1.1: Review 1Password - Server Credentials**

Go through 1Password and fill in this checklist:

#### **csb0 (cs0.barta.cm - 85.235.65.226)**

- [ ] **node-RED**
  - Username: `_____________`
  - Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **Mosquitto MQTT**
  - Username: `_____________`
  - Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **Telegram Bot (csb0bot)**
  - Bot Token: `_____________` (found in 1Password: Yes/No)
  - Bot URL: t.me/csb0bot
  - Notes: ******\_******

- [ ] **Bitwarden**
  - Admin Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **Traefik**
  - Dashboard Credentials: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **System Access**
  - SSH User: `mba`
  - SSH Password: (Do you use password or key-based auth?)
  - Root Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

#### **csb1 (cs1.barta.cm - 152.53.64.166)**

- [ ] **Grafana - caroline**
  - Username: `caroline`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **Grafana - otto**
  - Username: `otto`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **Grafana - gerhard**
  - Username: `gerhard`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **Grafana - markus**
  - Username: `markus`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **Grafana - mailina**
  - Username: `mailina`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **InfluxDB3**
  - Username: `admin`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **Hedgedoc**
  - Username: `hedgedoc`
  - Password: `_____________` (found in 1Password: Yes/No)

- [ ] **Docmost**
  - Credentials: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **Paperless-ngx**
  - Credentials: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **System Access**
  - SSH User: `mba`
  - SSH Password: `F0NyqFJD7rwmpct24c1` (from your previous message)
  - Root Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

#### **miniserver24 (192.168.1.101)**

- [ ] **MQTT Credentials**
  - Currently in: `/etc/secrets/mqtt.env` on server
  - Backed up in: 1Password? (Yes/No)
  - Notes: ******\_******

- [ ] **Tapo Camera**
  - Currently in: `/etc/secrets/tapoC210-00.env` on server
  - Backed up in: 1Password? (Yes/No)
  - Notes: ******\_******

- [ ] **System Access**
  - SSH: Key-based or password?
  - Root Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

#### **miniserver99 (192.168.1.99)**

- [ ] **AdGuard Home**
  - Username: `admin`
  - Password: Currently shows "REMOVED" in configuration.nix
  - Found in 1Password: `_____________` (Yes/No)
  - Notes: ******\_******

- [ ] **System Access**
  - SSH: Key-based or password?
  - Root Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

#### **msww87 (Remote Home Automation)**

- [ ] **System Access**
  - SSH: `_____________`
  - Root Password: `_____________` (found in 1Password: Yes/No)
  - Notes: ******\_******

- [ ] **Service Credentials**
  - Home Assistant: `_____________` (if applicable)
  - MQTT: `_____________` (if applicable)
  - Other services: `_____________`
  - Notes: ******\_******

### **Task 1.2: Categorize by Priority**

After reviewing 1Password, assign priority:

**HIGH Priority** (Active, critical services):

- [ ] csb0: ******\_******
- [ ] csb1: ******\_******

**MEDIUM Priority** (Stable, working):

- [ ] miniserver24: ******\_******
- [ ] miniserver99: ******\_******

**LOW Priority** (Can wait):

- [ ] msww87: ******\_******

### **Task 1.3: Test Server Access**

Verify you can SSH into each server:

```bash
# csb0
ssh mba@cs0.barta.cm
# Result: ___________

# csb1
ssh mba@cs1.barta.cm
# or: qc1 (if fish abbreviation works)
# Result: ___________

# miniserver24
ssh mba@192.168.1.101
# Result: ___________

# miniserver99
ssh mba@192.168.1.99
# Result: ___________

# msww87
ssh mba@msww87  # (or whatever the address is)
# Result: ___________
```

### **Task 1.4: Identify Missing Information**

List anything you're NOT sure about:

- [ ] Question 1: ******\_******
- [ ] Question 2: ******\_******
- [ ] Question 3: ******\_******

---

## 📊 **Phase 2: Design** (NEXT)

After completing Phase 1 inventory, we'll design:

### **2.1: Directory Structure**

```
~/Code/nixcfg/secrets/
├── secrets.nix              # SSH key registry (already exists)
│
├── servers/                 # NEW: Server secrets
│   ├── csb0-nodered.age
│   ├── csb0-mqtt.age
│   ├── csb0-telegram-bot.age
│   ├── csb0-bitwarden.age
│   ├── csb0-traefik.age
│   ├── csb1-grafana-users.age
│   ├── csb1-influxdb.age
│   ├── csb1-hedgedoc.age
│   ├── miniserver24-mqtt.age
│   ├── miniserver24-tapo.age
│   └── miniserver99-adguard.age
│
└── user/                    # NEW: User secrets
    └── git-work-identity.age
```

### **2.2: Encryption Strategy**

For each secret file, decide:

- **Who can decrypt**: Which SSH keys (your Mac, the server, both?)
- **File format**: `.env` format, JSON, plain text?
- **Naming convention**: `<server>-<service>.age`

### **2.3: Deployment Strategy**

For each server, decide:

- **Manual or automated**: Deploy manually first, automate later?
- **Declarative or runtime**: NixOS config or manual scripts?
- **Rollback plan**: How to revert if something breaks?

---

## 🔄 **Phase 3: Migrate** (FUTURE)

Step-by-step migration process:

### **3.1: Setup Infrastructure**

- [ ] Create `secrets/servers/` directory
- [ ] Create `secrets/user/` directory
- [ ] Update `secrets/secrets.nix` with new entries
- [ ] Test `agenix` command works

### **3.2: Migrate ONE Server (Pilot)**

- [ ] Choose pilot server (recommend: csb0 or csb1)
- [ ] Encrypt all secrets for that server
- [ ] Test decryption locally
- [ ] Deploy to server
- [ ] Verify services still work
- [ ] Document lessons learned

### **3.3: Migrate Remaining Servers**

- [ ] Apply same process to other servers
- [ ] One server at a time
- [ ] Test thoroughly after each

### **3.4: Migrate User Secrets**

- [ ] Git work identity
- [ ] SSH key backups (optional)
- [ ] Test on another machine (if available)

---

## ✅ **Phase 4: Verify** (FUTURE)

After migration:

- [ ] All services running correctly
- [ ] Can decrypt all secrets
- [ ] No plaintext secrets in configs
- [ ] Documentation updated
- [ ] Disaster recovery tested

---

## 🧹 **Phase 5: Cleanup** (FUTURE)

Only after everything works:

- [ ] Mark secrets in 1Password as "Migrated to agenix"
- [ ] Keep in 1Password as backup (don't delete yet!)
- [ ] Update `secrets-inventory.md` with final state
- [ ] Remove temporary planning docs

---

## 📝 **Notes & Decisions**

### **Key Decisions Made**

1. ✅ **Keep RSA 2048** - Secure until 2030, no urgent upgrade needed
2. ✅ **Use existing agenix** - Already in repo, proven in NixOS
3. ✅ **Incremental migration** - One server at a time, low risk
4. ✅ **Keep 1Password** - As backup during migration
5. ✅ **Plan first** - Document before executing (current phase)

### **Open Questions**

- [ ] Question: ******\_******
- [ ] Question: ******\_******
- [ ] Question: ******\_******

---

## 🚨 **Risks & Mitigations**

| Risk                  | Impact | Mitigation                       |
| --------------------- | ------ | -------------------------------- |
| Lock out of server    | HIGH   | Test SSH access before migration |
| Service downtime      | MEDIUM | Migrate during low-traffic time  |
| Lost secrets          | HIGH   | Keep 1Password until verified    |
| Wrong encryption keys | MEDIUM | Test decryption before deploy    |
| Forgot a secret       | LOW    | Thorough inventory phase         |

---

## 📅 **Timeline** (Estimate)

| Phase              | Time          | Status         |
| ------------------ | ------------- | -------------- |
| 1. Planning        | 30-60 min     | 🟡 In Progress |
| 2. Design          | 15 min        | ⬜ Pending     |
| 3. Migrate (pilot) | 30 min        | ⬜ Pending     |
| 4. Migrate (all)   | 1-2 hours     | ⬜ Pending     |
| 5. Verify          | 30 min        | ⬜ Pending     |
| 6. Cleanup         | 15 min        | ⬜ Pending     |
| **TOTAL**          | **3-5 hours** |                |

---

## 🎯 **Success Criteria**

We're done when:

- ✅ All server secrets encrypted in `secrets/servers/`
- ✅ All secrets can be decrypted and used
- ✅ All services running normally
- ✅ No plaintext secrets in git
- ✅ Documentation complete
- ✅ Disaster recovery plan tested
- ✅ 1Password marked as backup only

---

## 🔗 **Related Documents**

- [Secrets Inventory](./secrets-inventory.md) - Detailed inventory of all secrets
- [Secrets Architecture](../hosts/imac-mba-home/docs/reference/secrets-management.md) - Original design (superseded by this simpler agenix approach)
- [Hosts Overview](../hosts/README.md) - All servers and their purposes
- [DNS Configuration](./dns-barta-cm.md) - Domain and service mapping
