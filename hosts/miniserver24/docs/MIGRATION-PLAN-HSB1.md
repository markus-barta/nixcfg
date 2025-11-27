# miniserver24 → hsb1 Migration Plan

**Server**: miniserver24 → hsb1 (Home Server Barta 1)  
**Migration Type**: Hostname Rename + External Hokage + File Restructure  
**Risk Level**: 🟠 **HIGH** - Critical home automation infrastructure (133 Zigbee devices, HomeKit, cameras)  
**Status**: 📋 **PLANNING**  
**Created**: November 26, 2025  
**Last Updated**: November 26, 2025

---

## 📋 MIGRATION OVERVIEW

This migration is structured in **two major parts**:

### Part A: NixOS Migration (Phases 0-9)

- Hostname rename: `miniserver24` → `hsb1`
- External hokage consumer pattern
- DHCP/DNS updates
- System secrets migration to agenix
- **Risk**: 🔴 HIGH (SSH lockout possible without proper SSH key handling)

### Part B: File Restructure (Phase 10)

- Consolidate Docker config into main repo
- Consolidate user scripts into main repo
- Set up symlinks as "signposts"
- Retire separate `~/docker` git repo
- **Risk**: 🟡 MEDIUM (Docker may not start if paths wrong)

**Why this order?**

1. NixOS migration establishes the new hostname (`hsb1`)
2. File restructure then uses correct hostname in all configs from the start
3. Separated phases = clearer debugging if something breaks

---

## 📊 CURRENT STATE ANALYSIS

### Server Information

| Attribute          | Value                                               |
| ------------------ | --------------------------------------------------- |
| **Current Name**   | `miniserver24`                                      |
| **Target Name**    | `hsb1` (Home Server Barta 1)                        |
| **Role**           | Home automation hub                                 |
| **Hardware**       | Mac mini Late 2014 (Intel Core i7-4578U @ 3.00GHz)  |
| **RAM**            | 16 GB DDR3 (most powerful server in infrastructure) |
| **Storage**        | 512 GB Apple SSD (PCIe) on ZFS                      |
| **IP Address**     | `192.168.1.101` (static)                            |
| **Network**        | `enp3s0f0` (Gigabit Ethernet)                       |
| **NixOS Version**  | 25.11.20251105 (Xantusia)                           |
| **Current Uptime** | 13+ days (as of Nov 26, 2025)                       |
| **ZFS Host ID**    | `dabfdb01`                                          |

### Performance Comparison

| Feature         | miniserver24 (hsb1)   | hsb0                   | hsb8                   |
| --------------- | --------------------- | ---------------------- | ---------------------- |
| **CPU**         | i7-4578U @ 3.00GHz ⭐ | i5-2415M @ 2.30GHz     | i5-2415M @ 2.30GHz     |
| **Generation**  | 4th gen (Haswell) ⭐  | 2nd gen (Sandy Bridge) | 2nd gen (Sandy Bridge) |
| **RAM**         | 16 GB ⭐⭐            | 8 GB                   | 8 GB                   |
| **Storage**     | 512 GB SSD (PCIe) ⭐  | 250 GB SSD (SATA)      | 120 GB SSD (SATA)      |
| **Performance** | ⭐⭐⭐ Best           | ⭐⭐ Good              | ⭐⭐ Good              |

**Conclusion**: miniserver24/hsb1 is the most powerful server and runs the most demanding workloads.

---

## 🐳 DOCKER INFRASTRUCTURE

### Active Containers (11 services)

| Container               | Purpose                  | Ports          | Network | Critical |
| ----------------------- | ------------------------ | -------------- | ------- | -------- |
| **zigbee2mqtt**         | Zigbee bridge (133 devs) | 8888           | bridge  | 🔴 Yes   |
| **homeassistant**       | Smart home platform      | 8123 (default) | host    | 🔴 Yes   |
| **scrypted**            | Camera/HomeKit bridge    | varies         | host    | 🔴 Yes   |
| **mosquitto**           | MQTT broker              | 1883, 9001     | bridge  | 🔴 Yes   |
| **nodered**             | Automation flows         | 1880           | host    | 🟠 High  |
| **matter-server**       | Matter protocol          | varies         | host    | 🟡 Med   |
| **apprise**             | Notifications            | 8001           | bridge  | 🟡 Med   |
| **opus-stream-to-mqtt** | Audio streaming          | N/A            | host    | 🟢 Low   |
| **watchtower-weekly**   | Auto-updates             | N/A            | default | 🟢 Low   |
| **smtp**                | Mail relay               | 25 (internal)  | default | 🟢 Low   |
| **restic-cron-hetzner** | Backups to Hetzner       | N/A            | default | 🟠 High  |

### Current Docker Structure (BEFORE Migration)

```
~/docker/                          ← Separate git repo (to be retired)
├── docker-compose.yml             # Main compose file
├── Makefile
├── .git/                          # Separate repo: miniserver24-docker.git
├── mounts/                        # Runtime data (20+ folders)
│   ├── homeassistant/
│   ├── zigbee2mqtt/
│   ├── nodered/
│   └── ...
├── restic-cron/
└── smtp/
```

### Target Docker Structure (AFTER Migration - Phase 10)

```
~/Code/nixcfg/hosts/hsb1/
├── docker/                        ← Version controlled in main repo
│   ├── docker-compose.yml         # Uses ABSOLUTE paths to ~/docker-data/
│   ├── Makefile
│   └── .gitignore
├── users/
│   ├── mba/scripts/               ← Version controlled
│   └── kiosk/                     ← Version controlled
└── ...

~/docker              → symlink to ~/Code/nixcfg/hosts/hsb1/docker/
~/scripts             → symlink to ~/Code/nixcfg/hosts/hsb1/users/mba/scripts/

~/docker-data/                     ← Runtime data (NOT in git)
├── homeassistant/
├── zigbee2mqtt/
├── nodered/
└── ...

/home/kiosk/.config/openbox/autostart → symlink to repo
/home/kiosk/scripts                   → symlink to repo
```

### File Management Philosophy

**The Rule**: Every managed file is a symlink. If it's not a symlink, it's not managed.

| Location                                | Type           | Purpose                                 |
| --------------------------------------- | -------------- | --------------------------------------- |
| `~/Code/nixcfg/hosts/hsb1/`             | Git repo       | Source of truth for all configs         |
| `~/docker`                              | Symlink → repo | Familiar entry point for docker compose |
| `~/scripts`                             | Symlink → repo | Familiar entry point for scripts        |
| `~/docker-data/`                        | Directory      | Runtime data (not in git, persists)     |
| `/home/kiosk/.config/openbox/autostart` | Symlink → repo | Kiosk startup (managed)                 |
| `/home/kiosk/scripts/`                  | Symlink → repo | Kiosk scripts (managed)                 |

**Benefits**:

- Single source of truth (the repo)
- Symlinks act as "signposts" — obvious what's managed
- No sync scripts, no copy-on-deploy
- Changes are automatically in git when you edit through symlinks

---

## 🔎 HOSTNAME REFERENCE AUDIT

### ⚠️ CRITICAL: Artifacts Containing `miniserver24`

The following files, services, and configurations embed the hostname `miniserver24` and **MUST** be updated during migration:

#### NixOS Configuration (Part A - Phases 1-2)

| File/Location                             | Reference Type                | Action Required              |
| ----------------------------------------- | ----------------------------- | ---------------------------- |
| `configuration.nix` L314                  | `hostName = "miniserver24"`   | ✅ Change to `hsb1`          |
| `flake.nix` L151                          | `mkServerHost "miniserver24"` | ✅ Replace with `hsb1` def   |
| `configuration.nix` (mqtt-volume-control) | MQTT topic                    | ✅ Update to `home/hsb1/...` |

#### Docker/Container References (Part B - Phase 10)

| File                         | Reference              | Action Required     |
| ---------------------------- | ---------------------- | ------------------- |
| `docker-compose.yml` L1      | `# name: miniserver24` | ✅ Update to `hsb1` |
| Restic backup `MAIL_SUBJECT` | Contains hostname      | ✅ Update to `hsb1` |
| `restic-cron/hetzner/*`      | Backup scripts/logs    | 🔍 Audit naming     |

#### User Scripts (Part B - Phase 10)

| Script                           | Potential Reference         | Action Required               |
| -------------------------------- | --------------------------- | ----------------------------- |
| `~/scripts/deploy-miniserver.sh` | Script name + contents      | ✅ Rename to `deploy-hsb1.sh` |
| `~/scripts/fullvolume.sh`        | Comments reference hostname | ✅ Update comments            |
| `~/scripts/*.sh`                 | Any hostname refs           | 🔍 Audit all                  |

#### System Secrets (Part A - Phase 5)

| Secret                  | Reference                | Action Required           |
| ----------------------- | ------------------------ | ------------------------- |
| `/etc/secrets/mqtt.env` | `MQTT_HOST=miniserver24` | ✅ Update to `hsb1` or IP |

#### DHCP/DNS (Part A - Phase 4)

| Location                  | Reference      | Action Required            |
| ------------------------- | -------------- | -------------------------- |
| hsb0 AdGuard static lease | `miniserver24` | ✅ Add `hsb1` + keep alias |

#### External Documentation (Part A - Phase 9)

| File                | Reference                  | Action Required |
| ------------------- | -------------------------- | --------------- |
| `hosts/README.md`   | Multiple references        | ✅ Update all   |
| `hosts/hsb0/docs/*` | May reference miniserver24 | 🔍 Audit        |
| Root `README.md`    | Infrastructure refs        | 🔍 Audit        |

### Discovery Commands

```bash
# Find all miniserver24 references in nixcfg repo
rg -l "miniserver24" ~/Code/nixcfg/

# Find runtime references on server
rg -l "miniserver24" ~/scripts/ ~/docker/ /etc/secrets/ 2>/dev/null

# Find in Docker mounts (Home Assistant, Node-RED)
grep -r "miniserver24" ~/docker/mounts/homeassistant/
grep -r "miniserver24" ~/docker/mounts/nodered/
```

---

## 🔐 SECRETS INVENTORY

### User Secrets (`~/secrets/`)

These remain in place (not moved to repo for security):

| File                 | Purpose                              | Docker Service     |
| -------------------- | ------------------------------------ | ------------------ |
| `smarthome.env`      | Main smart home credentials (4.5 KB) | HA, Node-RED       |
| `zigbee2mqtt.env`    | Z2M MQTT credentials                 | zigbee2mqtt        |
| `influxdb3-csb1.env` | InfluxDB cloud connection            | Node-RED           |
| `watchtower.env`     | Notification URLs                    | watchtower         |
| `fritz.env`          | Fritz!Box credentials                | scripts            |
| `github.env`         | GitHub container registry            | watchtower-pidicon |
| `ghcr.env`           | GitHub container registry            | docker login       |
| `pidicon.env`        | Pixoo display config                 | pidicon            |
| `win10pc.env`        | Windows PC WoL/shutdown              | scripts            |

### System Secrets (`/etc/secrets/`) — Migrate to Agenix in Phase 5

| File              | Current Content                       | Agenix Target              |
| ----------------- | ------------------------------------- | -------------------------- |
| `mqtt.env`        | `MQTT_HOST`, `MQTT_USER`, `MQTT_PASS` | `secrets/mqtt-hsb1.age`    |
| `tapoC210-00.env` | `TAPO_C210_PASSWORD`                  | `secrets/tapo-c210-00.age` |

---

## ⚙️ NATIVE NIXOS SERVICES

### System Services

| Service                 | Purpose                            | Hostname Ref                       |
| ----------------------- | ---------------------------------- | ---------------------------------- |
| **apcupsd**             | APC UPS monitoring                 | No                                 |
| **apc-to-mqtt**         | Publish UPS status to MQTT (1 min) | No (uses `home/wz/battery/ups550`) |
| **mqtt-volume-control** | Control VLC volume via MQTT        | ✅ Yes (`home/miniserver24/...`)   |
| **lightdm**             | Display manager (kiosk auto-login) | No                                 |
| **openbox**             | Window manager for kiosk           | No                                 |
| **bluetooth**           | Bluetooth hardware support         | No                                 |
| **flirc**               | IR-USB receiver                    | No                                 |

### Kiosk User Configuration

| Item          | Location                                | Purpose             | Migration         |
| ------------- | --------------------------------------- | ------------------- | ----------------- |
| **autostart** | `/home/kiosk/.config/openbox/autostart` | VLC kiosk startup   | → Symlink to repo |
| **scripts/**  | `/home/kiosk/scripts/`                  | VLC control scripts | → Symlink to repo |
| **secrets/**  | `/home/kiosk/secrets/`                  | Camera credentials  | Keep in place     |

### mba User Scripts (`~/scripts/`)

| Script                 | Purpose                  | Migration                    |
| ---------------------- | ------------------------ | ---------------------------- |
| `apc-to-mqtt.sh`       | UPS status → MQTT        | → Move to repo               |
| `deploy-miniserver.sh` | Docker deployment        | → Rename to `deploy-hsb1.sh` |
| `deploy-pixoo*.sh`     | Pixoo display deployment | → Move to repo               |
| `fullvolume.sh`        | Audio fix for kiosk      | → Move to repo               |
| `reboot-all-fritz.sh`  | Fritz!Box reboot         | → Move to repo               |
| `vlc-kiosk-output.sh`  | Switch VLC stream        | → Move to repo               |
| `watchtower-*-run.sh`  | Container updates        | → Move to repo               |

---

## 📋 MIGRATION PHASES

---

# PART A: NIXOS MIGRATION (Phases 0-9)

---

### Phase 0: Pre-Migration Preparation

**Status**: ⏳ Ready to start  
**Duration**: 45 minutes  
**Risk**: 🟢 LOW  
**Build Required**: No

#### 0.1 Household Communication

- [ ] Inform household: "Smart home maintenance window - expect ~30min disruption"
- [ ] Preferred window: Evening (8-10 PM) or weekend afternoon
- [ ] Confirm no critical smart home dependencies

#### 0.2 Physical Access Verification

- [ ] Physical access available (HDMI + keyboard nearby)
- [ ] Or: secondary SSH path via IP (192.168.1.101)

#### 0.3 Backup Verification

```bash
# On miniserver24 - verify restic backups
docker logs restic-cron-hetzner --tail 50 | grep -E "(backup|error|success)"

# Verify Docker git state
cd ~/docker && git status  # Note any uncommitted changes
git log --oneline -3       # Note last commit hash: ____________

# Commit any pending Docker changes BEFORE migration
git add -A && git commit -m "pre-migration state"
```

#### 0.4 System Health Check

```bash
# System status
systemctl is-system-running            # Must be: running (or degraded with known issues)
zpool status                           # Must be: ONLINE, no errors
df -h /home                            # Note available space: ____GB

# Docker health
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"
# ^ Should return header only (all containers up)

# Critical services
apcaccess status | head -5             # UPS monitoring
systemctl is-active mqtt-volume-control
```

#### 0.5 Reference Discovery

```bash
# Find ALL miniserver24 references BEFORE migration
cd ~/Code/nixcfg
rg -l "miniserver24" . > /tmp/miniserver24-refs-before.txt
wc -l /tmp/miniserver24-refs-before.txt
cat /tmp/miniserver24-refs-before.txt
```

#### 0.6 Document Current Generation

```bash
# On miniserver24 - note for rollback
sudo nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3
# Current generation: ____
```

**Phase 0 Acceptance Criteria**:

- [ ] All health checks pass
- [ ] Backup verified recent (<24h)
- [ ] Docker repo changes committed
- [ ] Reference list documented
- [ ] Household notified
- [ ] Physical access confirmed

---

### Phase 1: Atomic Folder Rename + Flake Update

**Status**: ⏳ Pending  
**Duration**: 20 minutes  
**Risk**: 🟡 MEDIUM  
**Build Required**: ✅ YES - verify immediately after commit

> ⚠️ **CRITICAL**: Folder rename AND flake.nix update MUST be in the SAME commit to keep repo buildable.

#### 1.1 Pre-Flight Check

```bash
cd ~/Code/nixcfg
git status  # Must be clean
git pull    # Get latest
```

#### 1.2 Rename Folder

```bash
cd ~/Code/nixcfg/hosts
mv miniserver24 hsb1
```

#### 1.3 Update flake.nix (SAME COMMIT!)

Edit `flake.nix`:

**Remove** (around line 151):

```nix
miniserver24 = mkServerHost "miniserver24" [ disko.nixosModules.disko ];
```

**Add** (in nixosConfigurations block, after hsb0):

```nix
# Home Automation Server - Home Server Barta 1
# Using external hokage consumer pattern
hsb1 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # External hokage module
    ./hosts/hsb1/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
    # lib-utils already provided by self.commonArgs
  };
};
```

#### 1.4 Verify Build (MANDATORY before commit)

```bash
cd ~/Code/nixcfg
nix flake check 2>&1 | head -20  # Quick syntax check

# Full build test
nixos-rebuild build --flake .#hsb1 --show-trace

# If build fails: DO NOT COMMIT, fix issues first
```

#### 1.5 Commit Atomically

```bash
git add -A
git commit -m "refactor(hosts): rename miniserver24 → hsb1 + external hokage

- Rename folder: hosts/miniserver24 → hosts/hsb1
- Update flake.nix: replace mkServerHost with external hokage pattern
- Build verified: nixos-rebuild build --flake .#hsb1 passes

Part of unified naming scheme migration."
```

**Phase 1 Acceptance Criteria**:

- [ ] Folder renamed to `hsb1`
- [ ] flake.nix references `./hosts/hsb1/configuration.nix`
- [ ] flake.nix uses external hokage pattern
- [ ] `nixos-rebuild build --flake .#hsb1` succeeds
- [ ] Single atomic commit

---

### Phase 2: Update configuration.nix

**Status**: ⏳ Pending  
**Duration**: 25 minutes  
**Risk**: 🔴 HIGH - SSH lockout risk if done incorrectly  
**Build Required**: ✅ YES - verify after each sub-phase

#### 2.1 Remove Local Hokage Import

Edit `hosts/hsb1/configuration.nix`:

```diff
imports = [
  ./hardware-configuration.nix
-  ../../modules/hokage
  ./disk-config.zfs.nix
];
```

#### 2.2 Update Hokage Block (Replace Mixin Pattern)

**Find and replace** the entire `hokage = { ... }` block:

**Current** (mixin pattern):

```nix
hokage = {
  hostName = "miniserver24";
  zfs.hostId = "dabfdb01";
  audio.enable = true;
  serverMba.enable = true;
};
```

**Target** (external hokage pattern):

```nix
hokage = {
  hostName = "hsb1";
  userLogin = "mba";
  userNameLong = "Markus Barta";
  userNameShort = "Markus";
  userEmail = "markus@barta.com";
  role = "server-home";
  useInternalInfrastructure = false;
  useSecrets = true;
  useSharedKey = false;
  zfs.enable = true;
  zfs.hostId = "dabfdb01";
  audio.enable = true;  # Required for VLC kiosk
  programs.git.enableUrlRewriting = false;
};
```

#### 2.3 🚨 NON-NEGOTIABLE: SSH Key Security

> **WARNING**: Without this, you WILL be locked out. This happened on hsb8 on November 22, 2025.

Add **AFTER** the hokage block:

```nix
# ============================================================================
# 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8 INCIDENT (2025-11-22)
# ============================================================================
# The external hokage server-home module auto-injects external SSH keys
# (omega@yubikey, omega@rsa, etc). We use lib.mkForce to REPLACE these
# with ONLY authorized keys.
#
# Security Policy: hsb1 allows ONLY mba (Markus) SSH key.
# ============================================================================
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"  # mba@markus
  ];
};
```

#### 2.4 🚨 NON-NEGOTIABLE: Passwordless Sudo

```nix
# ============================================================================
# 🚨 PASSWORDLESS SUDO - Lost when removing serverMba mixin
# ============================================================================
security.sudo-rs.wheelNeedsPassword = false;
```

#### 2.5 ✅ Fish Shell Configuration (ALREADY DONE)

> **COMPLETED**: `sourcefish` function and `EDITOR=nano` are now centralized in
> `modules/shared/fish-config.nix` and automatically included via `common.nix`.
> No manual configuration needed for hsb1 - it will inherit these automatically.

#### 2.6 🎨 Starship Prompt (Tokyo Night Theme)

> **IMPORTANT**: The external hokage uses catppuccin starship by default.
> We disable it and use our shared Tokyo Night config instead.

Add **AFTER** the hokage block (near the SSH key section):

```nix
# ============================================================================
# 🎨 STARSHIP PROMPT - Use shared Tokyo Night config
# ============================================================================
# Disable external hokage's catppuccin starship, use our Tokyo Night theme.
# This preserves Nerd Font Unicode icons by using direct file copy.
# ============================================================================
hokage.programs.starship.enable = false;

home-manager.users.mba = {
  home.file.".config/starship.toml".source = ../../modules/shared/starship.toml;
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableBashIntegration = true;
  };
};
home-manager.users.root = {
  home.file.".config/starship.toml".source = ../../modules/shared/starship.toml;
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableBashIntegration = true;
  };
};
```

#### 2.7 Update MQTT Topic Reference

Find in configuration.nix (mqtt-volume-control service):

```diff
-  -t 'home/miniserver24/kiosk-vlc-volume'
+  -t 'home/hsb1/kiosk-vlc-volume'
```

#### 2.8 Verify Build

```bash
cd ~/Code/nixcfg
nixos-rebuild build --flake .#hsb1 --show-trace
# MUST succeed before committing
```

#### 2.9 Commit

```bash
git add hosts/hsb1/configuration.nix
git commit -m "refactor(hsb1): migrate to external hokage + security fixes

- Remove local hokage import
- Replace serverMba.enable mixin with explicit hokage options
- Add lib.mkForce SSH key override (prevent omega key injection)
- Add passwordless sudo (lost with mixin removal)
- Fish shell config now inherited from common.nix (sourcefish, EDITOR)
- Starship: disable hokage catppuccin, use shared Tokyo Night
- Update MQTT topic: home/miniserver24 → home/hsb1

Applies lessons from hsb8 SSH lockout incident (2025-11-22)."
```

**Phase 2 Acceptance Criteria**:

- [ ] No `../../modules/hokage` import
- [ ] No `serverMba.enable` present
- [ ] `userLogin = "mba"` added
- [ ] `role = "server-home"` added
- [ ] `lib.mkForce` SSH key block present (with ONLY mba@markus)
- [ ] `security.sudo-rs.wheelNeedsPassword = false` present
- [ ] Fish shell config inherited from `common.nix` (no manual config needed)
- [ ] `hokage.programs.starship.enable = false` present
- [ ] `home-manager.users.*.programs.starship` configured with shared TOML
- [ ] MQTT topic updated to `home/hsb1/...`
- [ ] `nixos-rebuild build --flake .#hsb1` succeeds

---

### Phase 3: Test Build on Server

**Status**: ⏳ Pending  
**Duration**: 15 minutes  
**Risk**: 🟢 LOW (no deployment)

#### 3.1 Push Changes

```bash
cd ~/Code/nixcfg
git push
```

#### 3.2 Build on miniserver24

```bash
ssh mba@192.168.1.101

cd ~/Code/nixcfg
git pull

# Test build locally
nixos-rebuild build --flake .#hsb1 --show-trace

# Verify result
ls -la result/
```

#### 3.3 Dry-Run Activation

```bash
sudo nixos-rebuild dry-activate --flake .#hsb1 2>&1 | tee /tmp/dry-activate.log
cat /tmp/dry-activate.log | grep -E "(would|restart|start|stop)"
```

**Phase 3 Acceptance Criteria**:

- [ ] Build succeeds on target server
- [ ] Dry-activate shows expected changes
- [ ] No unexpected service restarts

---

### Phase 4: Update DHCP/DNS on hsb0

**Status**: ⏳ Pending  
**Duration**: 15 minutes  
**Risk**: 🟡 MEDIUM

#### 4.1 Update Static Lease

```bash
ssh mba@192.168.1.99

cd ~/Code/nixcfg
agenix -e secrets/static-leases-hsb0.age
# Find miniserver24 entry, update hostname to hsb1
# KEEP the MAC address and IP (192.168.1.101) unchanged
# Consider adding alias: "hsb1,miniserver24" for backwards compatibility
```

#### 4.2 Deploy DHCP Changes

```bash
sudo nixos-rebuild switch --flake .#hsb0
systemctl status adguardhome
```

#### 4.3 Verify DNS Resolution

```bash
# From your Mac
nslookup hsb1.lan 192.168.1.99          # Should return 192.168.1.101
nslookup miniserver24.lan 192.168.1.99  # Should also work (alias)
```

**Phase 4 Acceptance Criteria**:

- [ ] Static lease updated in agenix
- [ ] hsb0 configuration deployed
- [ ] `hsb1.lan` resolves to `192.168.1.101`
- [ ] (Optional) `miniserver24.lan` alias works

---

### Phase 5: Migrate System Secrets to Agenix

**Status**: ⏳ Pending  
**Duration**: 30 minutes  
**Risk**: 🟡 MEDIUM

#### 5.1 Create Agenix Secret Files

```bash
cd ~/Code/nixcfg

agenix -e secrets/mqtt-hsb1.age
# Contents:
# MQTT_HOST=hsb1
# MQTT_USER=smarthome
# MQTT_PASS=<password from /etc/secrets/mqtt.env>

agenix -e secrets/tapo-c210-00.age
# Contents:
# TAPO_C210_PASSWORD=<password from /etc/secrets/tapoC210-00.env>
```

#### 5.2 Update secrets/secrets.nix

```nix
"mqtt-hsb1.age".publicKeys = [ mba hsb1 ];
"tapo-c210-00.age".publicKeys = [ mba hsb1 ];
```

#### 5.3 Update configuration.nix to Use Agenix

```nix
age.secrets = {
  mqtt-env = {
    file = ../../secrets/mqtt-hsb1.age;
    path = "/etc/secrets/mqtt.env";
    mode = "0400";
  };
  tapo-c210-00 = {
    file = ../../secrets/tapo-c210-00.age;
    path = "/etc/secrets/tapoC210-00.env";
    mode = "0400";
  };
};
```

#### 5.4 Verify and Commit

```bash
agenix -r
nixos-rebuild build --flake .#hsb1 --show-trace

git add secrets/ hosts/hsb1/configuration.nix
git commit -m "feat(hsb1): migrate system secrets to agenix"
```

**Phase 5 Acceptance Criteria**:

- [ ] `mqtt-hsb1.age` created and encrypted
- [ ] `tapo-c210-00.age` created and encrypted
- [ ] `secrets/secrets.nix` updated
- [ ] `configuration.nix` uses `age.secrets.*`
- [ ] Build succeeds

---

### Phase 6: (Reserved for Phase 10)

> **Note**: Hostname reference updates for Docker/scripts are now handled in Phase 10 (File Restructure) to avoid updating files twice.

---

### Phase 7: Deploy to Server

**Status**: ⏳ Pending  
**Duration**: 20 minutes  
**Risk**: 🔴 HIGH - Critical phase

#### 7.1 Pre-Deployment Final Checklist

**Environment**:

- [ ] At home with physical access capability
- [ ] Time available: 1 hour minimum
- [ ] Household notified
- [ ] No ongoing video calls or streaming

**Technical**:

- [ ] Phases 0-5 completed and committed
- [ ] `git status` clean
- [ ] Test build passed (Phase 3)
- [ ] DHCP updated (Phase 4)
- [ ] Secrets migrated (Phase 5)

**Safety**:

- [ ] Current NixOS generation noted: \_\_\_\_
- [ ] Know rollback command: `sudo nixos-rebuild switch --rollback`
- [ ] Physical access equipment located

#### 7.2 Execute Deployment

```bash
ssh mba@192.168.1.101  # Use IP, not hostname

cd ~/Code/nixcfg
git pull

echo "=== DEPLOYMENT STARTING ==="
echo "Time: $(date)"
echo "Current hostname: $(hostname)"
echo "Target: hsb1"
read -p "Press Enter to continue or Ctrl+C to abort..."

sudo nixos-rebuild switch --flake .#hsb1

echo "=== DEPLOYMENT COMPLETE ==="
echo "New hostname: $(hostname)"
```

#### 7.3 Immediate Verification

```bash
hostname                        # Must be: hsb1
systemctl is-system-running     # Must be: running

# SSH still works (from another terminal)
ssh mba@192.168.1.101 'echo SSH OK'

# Docker containers
docker ps --format "{{.Names}}: {{.Status}}" | grep -v "Up"
# Should return nothing (all up)
```

#### 7.4 If Anything Fails

```bash
# IMMEDIATE ROLLBACK
sudo nixos-rebuild switch --rollback

# If SSH broken, use physical access
```

**Phase 7 Acceptance Criteria**:

- [ ] Hostname is `hsb1`
- [ ] System is `running`
- [ ] SSH access works
- [ ] Docker containers running

---

### Phase 8: Comprehensive Verification

**Status**: ⏳ Pending  
**Duration**: 45 minutes  
**Risk**: 🟢 LOW

#### 8.1 System Health

```bash
hostname                           # hsb1
nixos-version                      # 25.11.xxxxx
systemctl is-system-running        # running
zpool status                       # ONLINE, no errors
```

#### 8.2 Docker Services

```bash
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"
# Should return header only

curl -sI http://192.168.1.101:8123 | head -1  # Home Assistant
curl -sI http://192.168.1.101:1880 | head -1  # Node-RED
curl -sI http://192.168.1.101:8888 | head -1  # Zigbee2MQTT
```

#### 8.3 Native Services

```bash
apcaccess status | grep -E "(STATUS|BCHARGE)"
systemctl is-active mqtt-volume-control
systemctl is-active display-manager
```

#### 8.4 MQTT Topic Verification

```bash
docker exec mosquitto mosquitto_pub -t 'home/hsb1/test' -m 'test'
docker exec mosquitto mosquitto_sub -t 'home/hsb1/#' -C 1 -W 5
```

#### 8.5 SSH Security Verification

```bash
# 🚨 CRITICAL: Verify SSH keys
cat /etc/ssh/authorized_keys.d/mba | cut -d' ' -f3
# Must show ONLY: mba@markus (and possibly blank lines)
# ❌ FAIL if you see: omega@yubikey, omega@rsa, etc.

sudo whoami  # Must not prompt for password
```

**Phase 8 Acceptance Criteria**:

- [ ] System healthy
- [ ] All Docker containers up
- [ ] Web UIs accessible
- [ ] MQTT topics working
- [ ] SSH keys correct (NO omega keys)
- [ ] Passwordless sudo works

---

### Phase 9: Documentation Update (Part A)

**Status**: ⏳ Pending  
**Duration**: 20 minutes  
**Risk**: 🟢 LOW

#### 9.1 Update Documentation

```bash
cd ~/Code/nixcfg
rg -l "miniserver24" . | grep -E "\.(md|nix)$" | grep -v archive
# Update each file found
```

Files to update:

- [ ] `hosts/README.md` - Migration status
- [ ] `hosts/hsb1/README.md` - Rename and update
- [ ] Any cross-references in other docs

#### 9.2 Commit

```bash
git add -A
git commit -m "docs(hsb1): update documentation after hostname migration"
git push
```

**Phase 9 Acceptance Criteria**:

- [ ] No active `miniserver24` refs in docs (except historical/archive)
- [ ] `hosts/README.md` updated

---

# PART B: FILE RESTRUCTURE (Phase 10)

---

### Phase 10: File Restructure + Symlinks

**Status**: ⏳ Pending  
**Duration**: 90 minutes  
**Risk**: 🟡 MEDIUM - Docker may not start if paths wrong  
**Prerequisites**: Part A (Phases 0-9) completed successfully

> **Purpose**: Consolidate Docker and scripts into main repo, set up symlinks as signposts.

#### 10.1 Create Folder Structure in Repo

```bash
cd ~/Code/nixcfg/hosts/hsb1

# Create directory structure
mkdir -p docker
mkdir -p users/mba/scripts
mkdir -p users/kiosk/openbox
mkdir -p users/kiosk/scripts
```

#### 10.2 Copy Docker Configuration

```bash
# Copy docker-compose.yml from server
scp mba@hsb1.lan:~/docker/docker-compose.yml ./docker/
scp mba@hsb1.lan:~/docker/Makefile ./docker/

# Create .gitignore for docker folder
cat > docker/.gitignore << 'EOF'
# Runtime data is stored in ~/docker-data/, not here
# This folder only contains the compose file and related configs
EOF
```

#### 10.3 Update docker-compose.yml Paths

Convert all relative paths to absolute paths pointing to `~/docker-data/`:

```yaml
# BEFORE (relative paths)
volumes:
  - ./mounts/homeassistant:/config
  - ./mounts/zigbee2mqtt:/app/data

# AFTER (absolute paths)
volumes:
  - /home/mba/docker-data/homeassistant:/config
  - /home/mba/docker-data/zigbee2mqtt:/app/data
```

**Full list of volume mounts to update:**

| Service       | Old Path                   | New Path                                |
| ------------- | -------------------------- | --------------------------------------- |
| zigbee2mqtt   | `./mounts/zigbee2mqtt`     | `/home/mba/docker-data/zigbee2mqtt`     |
| homeassistant | `./mounts/homeassistant`   | `/home/mba/docker-data/homeassistant`   |
| scrypted      | `./mounts/scrypted/volume` | `/home/mba/docker-data/scrypted/volume` |
| mosquitto     | `./mounts/mosquitto/*`     | `/home/mba/docker-data/mosquitto/*`     |
| nodered       | `./mounts/nodered/*`       | `/home/mba/docker-data/nodered/*`       |
| apprise       | `./mounts/apprise/*`       | `/home/mba/docker-data/apprise/*`       |
| matter-server | `./mounts/matter-server`   | `/home/mba/docker-data/matter-server`   |
| pidicon       | `./mounts/pidicon/*`       | `/home/mba/docker-data/pidicon/*`       |
| restic-cron   | `./restic-cron/*`          | Keep relative (scripts, not data)       |
| smtp          | `./smtp/*`                 | Keep relative (config, not data)        |

Also update hostname references:

```yaml
# Update comment
# name: hsb1

# Update restic backup subject
MAIL_SUBJECT: "💾 Restic Backup hsb1 (jhw22)"
```

#### 10.4 Copy mba Scripts

```bash
# Copy scripts from server
scp mba@hsb1.lan:~/scripts/apc-to-mqtt.sh ./users/mba/scripts/
scp mba@hsb1.lan:~/scripts/deploy-miniserver.sh ./users/mba/scripts/deploy-hsb1.sh
scp mba@hsb1.lan:~/scripts/fullvolume.sh ./users/mba/scripts/
scp mba@hsb1.lan:~/scripts/reboot-all-fritz.sh ./users/mba/scripts/
scp mba@hsb1.lan:~/scripts/vlc-kiosk-output.sh ./users/mba/scripts/
scp mba@hsb1.lan:~/scripts/set_vlc_volume.sh ./users/mba/scripts/
scp mba@hsb1.lan:~/scripts/deploy-pixoo*.sh ./users/mba/scripts/
scp mba@hsb1.lan:~/scripts/watchtower-*-run.sh ./users/mba/scripts/

# Update hostname references in scripts
cd users/mba/scripts
sed -i 's/miniserver24/hsb1/g' *.sh
```

#### 10.5 Copy Kiosk User Files

```bash
# Copy kiosk autostart
scp mba@hsb1.lan:/home/kiosk/.config/openbox/autostart ./users/kiosk/openbox/
# Note: Requires sudo on server, may need to copy via intermediate location

# Copy kiosk scripts
scp mba@hsb1.lan:/home/kiosk/scripts/vlc-kiosk-output.sh ./users/kiosk/scripts/
```

#### 10.6 Commit Repo Changes

```bash
cd ~/Code/nixcfg
git add hosts/hsb1/docker hosts/hsb1/users
git commit -m "feat(hsb1): add docker and user configs to repo

- Add docker-compose.yml with absolute paths to ~/docker-data/
- Add mba scripts
- Add kiosk autostart and scripts
- Update all hostname refs: miniserver24 → hsb1

Preparation for symlink-based file management."
git push
```

#### 10.7 Server-Side: Move Runtime Data

```bash
ssh mba@hsb1.lan

# Stop Docker containers
cd ~/docker
docker compose down

# Move runtime data to new location
mv ~/docker/mounts ~/docker-data

# Also move restic-cron and smtp (config, not data)
mv ~/docker/restic-cron ~/docker-data/
mv ~/docker/smtp ~/docker-data/
```

#### 10.8 Server-Side: Set Up Symlinks

```bash
# Pull latest repo with new structure
cd ~/Code/nixcfg
git pull

# Remove old directories
rm -rf ~/docker
rm -rf ~/scripts

# Create symlinks for mba user
ln -s ~/Code/nixcfg/hosts/hsb1/docker ~/docker
ln -s ~/Code/nixcfg/hosts/hsb1/users/mba/scripts ~/scripts

# Create symlinks for kiosk user (requires sudo)
sudo rm -rf /home/kiosk/scripts
sudo ln -s /home/mba/Code/nixcfg/hosts/hsb1/users/kiosk/scripts /home/kiosk/scripts
sudo ln -sf /home/mba/Code/nixcfg/hosts/hsb1/users/kiosk/openbox/autostart /home/kiosk/.config/openbox/autostart

# Verify symlinks
ls -la ~/docker ~/scripts
ls -la /home/kiosk/scripts /home/kiosk/.config/openbox/autostart
```

#### 10.9 Test Docker

```bash
cd ~/docker  # This is now a symlink to the repo
docker compose up -d

# Verify all containers start
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check logs for path errors
docker logs homeassistant --tail 20 | grep -i error
docker logs zigbee2mqtt --tail 20 | grep -i error
```

#### 10.10 Test Kiosk

```bash
# Restart display manager to reload kiosk autostart
sudo systemctl restart display-manager

# Verify kiosk display shows camera feed
# (Physical check required)
```

#### 10.11 Retire Old Docker Repo

```bash
# The old ~/docker was a separate git repo
# After verifying everything works, you can delete the remote:
# git remote remove origin  (if you want to keep local history)
# Or just leave it - the symlink now points to nixcfg

# Update README about the change
echo "Docker configuration moved to nixcfg repo" > ~/docker-data/README.md
```

#### 10.12 Final Verification

```bash
# Verify symlinks work correctly
ls ~/docker/docker-compose.yml       # Should show file
ls ~/scripts/apc-to-mqtt.sh          # Should show file

# Verify editing through symlink works
echo "# test" >> ~/docker/docker-compose.yml
cd ~/Code/nixcfg
git status  # Should show docker-compose.yml modified
git checkout hosts/hsb1/docker/docker-compose.yml  # Revert test

# Verify Docker runs
docker compose ps

# Verify all services accessible
curl -sI http://localhost:8123 | head -1
curl -sI http://localhost:1880 | head -1
curl -sI http://localhost:8888 | head -1
```

**Phase 10 Acceptance Criteria**:

- [ ] `~/docker` is symlink to repo
- [ ] `~/scripts` is symlink to repo
- [ ] `/home/kiosk/.config/openbox/autostart` is symlink to repo
- [ ] `/home/kiosk/scripts` is symlink to repo
- [ ] `~/docker-data/` contains runtime data
- [ ] All 11 Docker containers running
- [ ] Kiosk display shows camera feed
- [ ] Editing through symlink reflects in git status
- [ ] No `miniserver24` references in active configs

---

### Phase 11: Final Documentation + Archive

**Status**: ⏳ Pending  
**Duration**: 20 minutes  
**Risk**: 🟢 LOW

#### 11.1 Update Host README

Update `hosts/hsb1/README.md` with new file management documentation:

```markdown
## File Management

Managed files use symlinks to the repo:

- `~/docker` → `hosts/hsb1/docker/`
- `~/scripts` → `hosts/hsb1/users/mba/scripts/`
- `/home/kiosk/.config/openbox/autostart` → `hosts/hsb1/users/kiosk/openbox/autostart`
- `/home/kiosk/scripts` → `hosts/hsb1/users/kiosk/scripts/`

Runtime data (not in git): `~/docker-data/`

**The Rule**: Every managed file is a symlink. If it's not a symlink, it's not managed.
```

#### 11.2 Archive Migration Plan

```bash
cd ~/Code/nixcfg/hosts/hsb1
mv docs/MIGRATION-PLAN-HSB1.md archive/"MIGRATION-PLAN-HSB1 [DONE].md"
```

#### 11.3 Final Commit

```bash
git add -A
git commit -m "docs(hsb1): complete migration miniserver24 → hsb1

- Update README with file management documentation
- Archive migration plan

Migration completed: [DATE]
- Part A (NixOS): Hostname + external hokage
- Part B (Files): Docker + scripts in repo with symlinks"
git push
```

**Phase 11 Acceptance Criteria**:

- [ ] README updated with file management docs
- [ ] Migration plan archived
- [ ] All changes pushed

---

## 🛡️ ROLLBACK PROCEDURES

### Scenario 1: Build Fails (Any Phase)

**Impact**: None (no changes deployed)

```bash
# Fix configuration and retry
nano hosts/hsb1/configuration.nix
nixos-rebuild build --flake .#hsb1 --show-trace
```

### Scenario 2: NixOS Deployment Fails

**Impact**: System in mixed state

```bash
sudo nixos-rebuild switch --rollback
hostname  # Should revert
```

### Scenario 3: Docker Fails After Phase 10

**Impact**: Home automation offline

```bash
# Check container logs
docker logs <container> --tail 50

# Common issue: wrong paths
# Fix: Update docker-compose.yml paths
nano ~/docker/docker-compose.yml
docker compose up -d
```

### Scenario 4: SSH Lockout

**Impact**: No remote access

1. Connect HDMI + keyboard
2. Login as `mba`
3. `sudo nixos-rebuild switch --rollback`

### Scenario 5: Symlink Issues

**Impact**: Commands fail, docker won't start

```bash
# Verify symlinks point to correct locations
ls -la ~/docker ~/scripts

# If broken, recreate:
rm ~/docker
ln -s ~/Code/nixcfg/hosts/hsb1/docker ~/docker
```

---

## 📅 RECOMMENDED SCHEDULE

### Time Estimates

| Phase            | Duration     | Cumulative | Description                   |
| ---------------- | ------------ | ---------- | ----------------------------- |
| 0                | 45 min       | 45 min     | Pre-flight checks             |
| 1-2              | 45 min       | 1h 30m     | Folder rename + config update |
| 3                | 15 min       | 1h 45m     | Test build                    |
| 4                | 15 min       | 2h 00m     | DHCP update                   |
| 5                | 30 min       | 2h 30m     | Agenix secrets                |
| 7                | 20 min       | 2h 50m     | Deploy                        |
| 8                | 45 min       | 3h 35m     | Verification                  |
| 9                | 20 min       | 3h 55m     | Docs (Part A)                 |
| **Part A Total** | **~4 hours** |            |                               |
| 10               | 90 min       | 5h 25m     | File restructure              |
| 11               | 20 min       | 5h 45m     | Final docs                    |
| **Total**        | **~6 hours** |            | (with buffer)                 |

### Best Time

- 🌙 **Evening (starting 6 PM)** - Can complete Part A before bed
- 📅 **Weekend** - Full day available for both parts

### Recommended Split

- **Day 1**: Part A (Phases 0-9) - NixOS migration
- **Day 2**: Part B (Phases 10-11) - File restructure

---

## 🎓 LESSONS FROM PREVIOUS MIGRATIONS

### From hsb8 Incident (November 22, 2025)

- **SSH lockout** after removing `serverMba.enable`
- **Fix**: `lib.mkForce` for SSH keys (now in Phase 2.3)
- **Impact**: 2 hours recovery via physical console

### From hsb0 Migration (November 22, 2025)

- External hokage pattern works reliably
- Zero downtime with NixOS switch
- `lib.mkForce` SSH fix worked perfectly

### Applied to hsb1

| Lesson                 | Application                                        |
| ---------------------- | -------------------------------------------------- |
| SSH lockout prevention | Phase 2.3: `lib.mkForce` (NON-NEGOTIABLE)          |
| Passwordless sudo      | Phase 2.4: Explicit config                         |
| Fish functions         | ✅ Centralized in `modules/shared/fish-config.nix` |
| Test build first       | Phase 3: Build before deploy                       |
| Atomic commits         | Phase 1: Folder + flake together                   |
| File management        | Phase 10: Symlinks as signposts                    |

---

## 🔗 RELATED DOCUMENTATION

- [hsb0 Migration Plan](../../hsb0/docs/MIGRATION-PLAN-HOKAGE.md) - Completed reference
- [hsb8 enable-ww87](../../hsb8/docs/enable-ww87.md) - Script pattern reference
- [Hosts README](../../README.md) - Architecture overview
- [Hokage Options](../../../docs/hokage-options.md) - Module reference

---

**Status**: 📋 **PLANNING** - Ready for execution  
**Next Step**: Review plan → Start Phase 0  
**Author**: AI Assistant (with Markus Barta)  
**Created**: November 26, 2025  
**Last Updated**: November 26, 2025
