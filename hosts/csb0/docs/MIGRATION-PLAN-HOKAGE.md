# csb0 → External Hokage Consumer Migration Plan

**Server**: csb0 (Cloud Server Barta 0)
**Migration Type**: External Hokage Consumer Pattern
**Risk Level**: 🟠 **MEDIUM-HIGH** - Smart home & IoT critical services
**Status**: ✅ **COMPLETED** - Deployed and reboot verified
**Created**: November 29, 2025
**Last Updated**: December 6, 2025 (Post-Incident)

---

## 🚨 CURRENT STATUS (Updated 2025-12-06)

### ✅ MIGRATION COMPLETED

| Item                | Status             | Notes                                           |
| ------------------- | ------------------ | ----------------------------------------------- |
| **Running Config**  | ✅ External Hokage | Gen 27, reboot verified                         |
| **Uzumaki Pattern** | ✅ New pattern     | `uzumaki = { enable = true; role = "server"; }` |
| **StaSysMo**        | ✅ Enabled         | System monitoring in prompt                     |
| **Static IP**       | ✅ Correct values  | /22 subnet, 85.235.64.1 gateway                 |
| **Password Auth**   | ✅ Enabled         | VNC recovery fallback                           |
| **Reboot Test**     | ✅ PASSED          | 2025-12-06 after fix                            |

### Incident (2025-12-06) - RESOLVED

**Initial deploy FAILED** due to wrong network configuration. Fixed and re-deployed.
See [Incident Report](#-incident-report-2025-12-06-network-lockout) below.

### Uzumaki Compatibility ✅

csb0's `configuration.nix` already imports `../../modules/uzumaki/server.nix` which provides:

| Feature               | Source             | Current (old build)      | After Deploy |
| --------------------- | ------------------ | ------------------------ | ------------ |
| `pingt` function      | uzumaki/common.nix | ✅ Working               | ✅           |
| `sourcefish` function | uzumaki/common.nix | ✅ Working               | ✅           |
| `sourceenv` function  | uzumaki/common.nix | ✅ Working               | ✅           |
| `stress` function     | uzumaki/common.nix | ❌ Missing (added later) | ✅ NEW       |
| `stasysmod` function  | uzumaki/common.nix | ❌ Missing (added later) | ✅ NEW       |
| `helpfish` function   | uzumaki/common.nix | ❌ Missing (added later) | ✅ NEW       |
| `EDITOR=nano`         | uzumaki/server.nix | ✅ Working               | ✅           |
| zellij package        | uzumaki/server.nix | ✅ Working               | ✅           |

### Current State (Validated 2025-12-05)

| Check             | Status           | Notes                       |
| ----------------- | ---------------- | --------------------------- |
| NixOS Version     | 25.11 Xantusia   | Same as csb1                |
| Docker Containers | ✅ 8/8 running   | All healthy                 |
| SSH Access        | ✅ Working       | Port 2222                   |
| Sudo              | ✅ Passwordless  | Works                       |
| ZFS Pools         | ✅ Healthy       | 29G free                    |
| nixbit            | ❌ Not installed | Expected (old local hokage) |
| pingt/sourcefish  | ✅ Working       | uzumaki functions           |
| stress/helpfish   | ❌ Missing       | Will be added               |

---

## 🎯 Migration Overview

### Current State

| Attribute       | Value                                              |
| --------------- | -------------------------------------------------- |
| **Hostname**    | `csb0`                                             |
| **Role**        | Smart home automation, IoT hub, MQTT broker        |
| **Criticality** | 🟠 **MEDIUM-HIGH** - Family uses daily             |
| **OS**          | NixOS 24.11.20240926.1925c60 (Vicuna)              |
| **Uptime**      | 267 days (VERY STABLE!)                            |
| **Structure**   | OLD modules/mixins (local fork on server)          |
| **Config**      | Local `~/nixcfg` on server (drifted from main)     |
| **Services**    | 8 Docker containers                                |
| **Backup**      | Daily at 01:30 AM (manages BOTH servers' cleanup!) |

### Target State

| Attribute     | Value                                              |
| ------------- | -------------------------------------------------- |
| **OS**        | NixOS 25.11 (Xantusia) or keep current             |
| **Structure** | External hokage consumer from `github:pbek/nixcfg` |
| **Config**    | New configuration in main repo (`~/Code/nixcfg`)   |
| **Services**  | Same Docker services (preserved)                   |
| **Backup**    | Keep Docker restic container (manages both!)       |

---

## 🚨 Critical Differences from csb1

| Aspect             | csb1 (Done)     | csb0 (This server)        |
| ------------------ | --------------- | ------------------------- |
| **Criticality**    | Monitoring/docs | Smart home/IoT (family!)  |
| **Impact if down** | Data gap        | Garage door, automation   |
| **Cross-server**   | Receives MQTT   | **Provides MQTT to csb1** |
| **Uptime**         | ~200 days       | **267 days**              |
| **User impact**    | Just you        | Family, neighbors         |
| **Backup manager** | Backed up       | **Manages both servers**  |

### Services Impact Analysis

| Service        | Domain           | Impact if Down                      |
| -------------- | ---------------- | ----------------------------------- |
| Node-RED       | home.barta.cm    | 🔴 Smart home automation stops      |
| MQTT/Mosquitto | -                | 🔴 IoT devices disconnect, csb1 too |
| Telegram Bot   | -                | 🔴 Garage door control BROKEN       |
| Traefik        | traefik.barta.cm | 🟠 SSL/routing broken               |
| Cypress        | -                | 🟡 Solar scraping stops             |
| Backup/Restic  | -                | 🔴 Both servers lose backups!       |

---

## ✅ Lessons Learned from csb1 (2025-12-05)

### What Worked on csb1 Migration

1. **`lib.mkForce` for SSH keys** - Essential to block omega key injection ✅ APPLIED
2. **Temporary password auth** - Critical safety net during migration ✅ APPLIED
3. **Node-RED/hsb1 SSH key** - Must include for automation ✅ PRESENT
4. **Flake overlays fix** - Removed obsolete overlays code ✅ FIXED
5. **uzumaki/server.nix import** - Uses `lib.mkAfter` for layering ✅ PRESENT
6. **Pre-deploy baseline capture** - Document current state
7. **Immediate verification** - Check SSH, sudo, Docker, nixbit

### What's Already Applied to csb0

```nix
# 1. SSH KEY OVERRIDE (prevents lockout!)
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABA..."  # mba key
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE..."    # hsb1/miniserver24 key
  ];
};

# 2. TEMPORARY PASSWORD AUTH (migration safety)
services.openssh.settings.PasswordAuthentication = lib.mkForce true;

# 3. PASSWORDLESS SUDO
security.sudo-rs.wheelNeedsPassword = false;

# 4. HOKAGE SETTINGS
hokage = {
  role = "server-remote";
  useInternalInfrastructure = false;
  useSecrets = true;
  useSharedKey = false;  # No omega keys!
};
```

---

## 📊 Pre-Migration Checklist

### Information Gathering

- [x] All SSH access documented
- [x] All service credentials in 1Password/secrets
- [x] Backup system verified
- [x] Docker structure mapped (8 containers)
- [x] Data volumes identified
- [x] Dependencies documented (csb1 needs MQTT!)
- [x] Telegram bot configured
- [x] 267 days uptime confirmed

### Configuration Preparation

- [ ] Create `hosts/csb0/configuration.nix` in main repo
- [ ] Create `hosts/csb0/hardware-configuration.nix`
- [ ] Create `hosts/csb0/disk-config.zfs.nix`
- [ ] Add csb0 to `flake.nix`
- [ ] Set hokage external consumer flags
- [ ] Configure Mosquitto group (GID 1883)
- [ ] Include hsb1 SSH key for Node-RED automation
- [ ] Test build locally: `nix build .#nixosConfigurations.csb0...`

### Backup Verification

- [ ] Trigger manual pre-migration backup
- [ ] Verify backup completed
- [ ] Create Netcup snapshot
- [ ] Archive live config to `archive/` folder

---

## 🔄 Configuration Changes

### Before (Current - Local Mixins)

```nix
# hosts/csb0/configuration.nix (on server)
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/mixins/server-remote.nix
    ../../modules/mixins/server-mba.nix
    ../../modules/mixins/zellij.nix
    ./disk-config.zfs.nix
  ];

  networking.hostId = "dabfdc01";
  networking.hostName = "csb0";
  # ...
}
```

### After (Target - External Hokage)

```nix
# hosts/csb0/configuration.nix (in main repo)
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
  ];

  hokage = {
    hostName = "csb0";
    userLogin = "mba";
    role = "server-remote";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdc01";
  };

  # SSH key override (lib.mkForce!)
  users.users.mba.openssh.authorizedKeys.keys = lib.mkForce [ ... ];

  # Mosquitto group permissions
  users.groups.mosquitto.gid = 1883;
  # ...
}
```

---

## 🚀 Execution Steps

### Phase 1: Pre-Migration

```bash
# 1. Run all tests
cd hosts/csb0/tests
for f in T*.sh; do ./$f; done

# 2. Run restart safety check
cd ../scripts
./restart-safety.sh

# 3. Create backups
./create-netcup-snapshot.sh  # If exists
ssh -p 2222 mba@cs0.barta.cm 'docker exec csb0-restic-cron-hetzner-1 /usr/local/bin/run_backup.sh'

# 4. Archive live config
rsync -avz -e 'ssh -p 2222' mba@cs0.barta.cm:~/nixcfg/ hosts/csb0/archive/$(date +%Y-%m-%d)-pre-hokage/
```

### Phase 2: Deploy

```bash
# 1. SSH to server
ssh -p 2222 mba@cs0.barta.cm

# 2. Pull new config
cd ~/nixcfg  # or ~/Code/nixcfg
git fetch origin && git reset --hard origin/main

# 3. Deploy
sudo nixos-rebuild switch --flake .#csb0

# 4. Verify
nixos-version
docker ps
```

### Phase 3: Post-Migration

```bash
# From local machine
cd hosts/csb0/migrations/2025-11-hokage
./02-post-verify.sh
./03-rollback.sh

# Verify csb1 still receiving MQTT!
ssh -p 2222 mba@cs1.barta.cm 'docker logs csb1-influxdb-1 --tail 10'
```

---

## 🔄 Rollback Options

1. **NixOS Rollback** (fastest): `sudo nixos-rebuild switch --rollback`
2. **GRUB Menu** (if SSH broken): VNC → Select previous generation
3. **Netcup Snapshot** (full disk): SCP panel → Restore snapshot
4. **Restic Backup** (data only): Restore Docker volumes

---

## ✅ Post-Migration Verification

### Pre-Deploy Baseline (CAPTURE BEFORE DEPLOY!)

```bash
# SSH to csb0 and capture baseline
ssh -p 2222 mba@csb0 << 'EOF'
echo "=== BASELINE CAPTURED: $(date -Iseconds) ==="

echo -e "\n=== DOCKER CONTAINERS ==="
docker ps --format 'table {{.Names}}\t{{.Status}}'

echo -e "\n=== FISH FUNCTIONS ==="
fish -i -c 'for f in pingt sourcefish stress helpfish; echo -n "$f: "; type $f >/dev/null 2>&1 && echo OK || echo MISSING; end'

echo -e "\n=== ZFS POOLS ==="
zpool status -x

echo -e "\n=== DISK USAGE ==="
df -h / /home
EOF
```

### Immediate Checks (Within 5 minutes of deploy)

#### 🚨 CRITICAL - SSH & Security

- [ ] SSH access working: `ssh -p 2222 mba@csb0 "echo OK"`
- [ ] 🚨 SSH keys verified - ONLY mba keys present
- [ ] 🚨 NO `omega@*` keys in authorized_keys
- [ ] 🚨 Passwordless sudo working: `ssh -p 2222 mba@csb0 "sudo whoami"`

#### 🐳 Docker Services (8 containers must be running)

- [ ] All containers UP: `docker ps --format '{{.Names}}: {{.Status}}' | grep -c "Up"` = 8
- [ ] Node-RED: `curl -s https://home.barta.cm/ -o /dev/null -w '%{http_code}'`
- [ ] MQTT/Mosquitto: `docker exec csb0-mosquitto-1 mosquitto_pub -t test -m test`
- [ ] Traefik: ports 80, 443 responding
- [ ] Bitwarden: healthy

#### 🐟 Uzumaki (Fish functions)

- [ ] pingt works: `ssh -p 2222 mba@csb0 "fish -i -c 'type pingt'"`
- [ ] sourcefish works: `ssh -p 2222 mba@csb0 "fish -i -c 'type sourcefish'"`
- [ ] helpfish works: `ssh -p 2222 mba@csb0 "fish -i -c 'helpfish'" | head -5`
- [ ] EDITOR set: `ssh -p 2222 mba@csb0 "fish -i -c 'echo \$EDITOR'"` = nano

#### 🔧 External Hokage Indicators

- [ ] nixbit installed: `ssh -p 2222 mba@csb0 "which nixbit"`
- [ ] nixbit works: `ssh -p 2222 mba@csb0 "nixbit --version"`

#### 🏠 Smart Home Critical

- [ ] **Telegram Bot**: Test garage door command
- [ ] **MQTT to csb1**: `ssh -p 2222 mba@csb1 "docker logs csb1-influxdb-1 --tail 5"` shows data
- [ ] **Node-RED flows**: Check dashboard at home.barta.cm

### Container Status Reference

| Container                   | Purpose          | Health Check       |
| --------------------------- | ---------------- | ------------------ |
| csb0-traefik-1              | Reverse proxy    | ports 80, 443 open |
| csb0-nodered-1              | Smart home       | HTTP 200, healthy  |
| csb0-mosquitto-1            | MQTT broker      | pub/sub works      |
| csb0-bitwarden-1            | Password manager | HTTP 200, healthy  |
| csb0-bitwarden-db-1         | PostgreSQL       | running            |
| csb0-smtp-1                 | Email relay      | running            |
| csb0-restic-cron-hetzner-1  | Backups          | running            |
| csb0-docker-proxy-traefik-1 | Docker API       | running            |

### 24-Hour Monitoring

- [ ] All services still running
- [ ] Backup completed successfully (next night @ 01:30)
- [ ] No unexpected restarts: `docker ps -a --filter "status=restarting"`
- [ ] csb1 still receiving MQTT data

---

## 📊 Risk Assessment

| Risk                  | Mitigation                            |
| --------------------- | ------------------------------------- |
| SSH lockout           | `lib.mkForce` SSH keys, password auth |
| Smart home downtime   | Quick switch (~2 min), test all flows |
| MQTT broker down      | csb1 can buffer, data gap acceptable  |
| Garage door broken    | Test Telegram bot immediately         |
| Backup manager broken | Verify cleanup runs next day          |
| Cross-server impact   | Test csb1 MQTT connection after       |

**Confidence Level**: 🟢 HIGH (csb1 successful, same pattern)

---

## 🚀 Deploy Command

```bash
# Build on server (recommended for cloud VPS)
ssh -p 2222 mba@csb0 "cd ~/nixcfg && git pull && sudo nixos-rebuild switch --flake .#csb0"
```

### Quick Health Check After Deploy

```bash
ssh -p 2222 mba@csb0 << 'EOF'
echo "=== SSH: OK ==="
echo "=== Sudo: $(sudo whoami) ==="
echo "=== Docker containers: $(docker ps -q | wc -l) running ==="
echo "=== nixbit: $(which nixbit 2>/dev/null || echo 'NOT FOUND') ==="
fish -i -c 'echo "=== pingt: $(type pingt >/dev/null 2>&1 && echo OK || echo MISSING) ==="'
fish -i -c 'echo "=== EDITOR: $EDITOR ==="'
EOF
```

---

## 🚨 INCIDENT REPORT: 2025-12-06 Network Lockout

### Timeline (All times CET)

| Time   | Event                                                  |
| ------ | ------------------------------------------------------ |
| ~11:00 | Started deployment of csb0 with `nixos-rebuild switch` |
| ~11:05 | **SSH connection lost** - csb0 became unreachable      |
| ~11:10 | Ping to 85.235.65.226 failing                          |
| ~11:15 | Accessed Netcup VNC console                            |
| ~11:20 | Attempted `init=/bin/sh` recovery                      |
| ~11:30 | VNC keyboard issues: Cannot type `:`, `-`, `\`, `\|`   |
| ~12:00 | Struggled with minimal shell and keyboard problems     |
| ~12:30 | Set mba password via passwd in init shell              |
| ~12:35 | Rebooted to new gen, VNC login now works               |
| ~12:45 | SSH still fails - network misconfigured                |
| ~13:00 | Booted Gen 22 (2024-09-29) - **SSH WORKS!**            |
| ~13:05 | DHCP analysis reveals correct values                   |
| ~13:15 | Fixed configuration, committed, deployed               |
| ~13:18 | Reboot test - **SUCCESS!**                             |

### Root Cause Analysis

**TWO configuration errors caused the lockout:**

| Setting     | Wrong (Our Config) | Correct (DHCP) | Impact                    |
| ----------- | ------------------ | -------------- | ------------------------- |
| **Subnet**  | `/24`              | `/22`          | Gateway unreachable       |
| **Gateway** | `85.235.65.1`      | `85.235.64.1`  | Packets sent to wrong IP! |

**Why we got it wrong:**

- Assumed gateway pattern from csb1 (`152.53.64.1` for `/24`)
- Applied same pattern: `85.235.65.226` → `85.235.65.1`
- But csb0 is on `/22` network, gateway is at start of range: `85.235.64.1`

**Why manual /22 fix didn't work during recovery:**

- We added correct `/22` subnet BUT kept wrong gateway `85.235.65.1`
- Packets were routed to a non-existent gateway!

### VNC Keyboard Issues (Netcup Console)

**Broken keys** (German/international layout mismatch):

- `:` (colon) - impossible to type
- `-` (hyphen) - impossible to type
- `\` (backslash) - impossible to type
- `|` (pipe) - impossible to type

**Working keys**: Letters, numbers, `=`, `/`, `.`

**Impact**: Most Linux commands require these characters, making recovery extremely difficult.

### Recovery via Old Generation

**Gen 22 (2024-09-29)** was last known-good:

- Used DHCP via NetworkManager
- All network values correct (from Netcup DHCP)
- SSH worked immediately after boot

**DHCP values captured:**

```
IP4.ADDRESS[1]: 85.235.65.226/22
IP4.GATEWAY:    85.235.64.1     ← CORRECT!
IP4.DNS[1]:     46.38.225.230
IP4.DNS[2]:     46.38.252.230
```

### Lessons Learned

1. **ALWAYS check gateway from DHCP** before setting static IP
2. **Subnet mask affects gateway location** - /22 gateway is NOT at .X.1
3. **VNC keyboard is unreliable** - have alternative recovery methods
4. **Keep one known-good generation** for emergency recovery
5. **Document network values** in easily accessible location

### Files Changed

| File                             | Change                                   |
| -------------------------------- | ---------------------------------------- |
| `hosts/csb0/configuration.nix`   | Fixed prefixLength (24→22), gateway, DNS |
| `hosts/csb0/ip-85.235.65.226.md` | Documented correct network values        |
| `docs/private/PICK-UP-HERE.md`   | Full incident documentation              |

---

## 📚 Related Documentation

- [SSH Key Security Note](./SSH-KEY-SECURITY-NOTE.md) - Why lib.mkForce
- [Emergency Runbook](../secrets/RUNBOOK.md) - All credentials & procedures
- [csb1 Migration Plan](../../csb1/docs/MIGRATION-PLAN-HOKAGE.md) - Reference
- [PICK-UP-HERE.md](../../../docs/private/PICK-UP-HERE.md) - Full incident details

---

**STATUS**: ✅ COMPLETED - Deployed and reboot verified (2025-12-06)
**CONFIDENCE**: 🟢 HIGH - Network configuration validated from DHCP
**NEXT**: Monitor for 24h, then disable password auth if stable
