# csb0 → External Hokage Consumer Migration Plan

**Server**: csb0 (Cloud Server Barta 0)
**Migration Type**: External Hokage Consumer Pattern
**Risk Level**: 🟠 **MEDIUM-HIGH** - Smart home & IoT critical services
**Status**: ⏳ **READY TO DEPLOY** - csb1 successful, flake evaluates
**Created**: November 29, 2025
**Last Updated**: December 5, 2025

---

## 🚨 CURRENT STATUS (Validated 2025-12-05)

### Reality Check

| Item                | Status                         | Notes                                                  |
| ------------------- | ------------------------------ | ------------------------------------------------------ |
| **Running Config**  | ❌ OLD local hokage            | No `nixbit` installed (external hokage signature tool) |
| **Flake Evaluates** | ✅ PASS                        | `nix eval '.#nixosConfigurations.csb0'` works          |
| **External Hokage** | ⏳ Configured, READY to deploy | flake.nix correct, same pattern as csb1                |
| **Last Rebuild**    | Unknown (267 days uptime!)     | Needs new rebuild for external hokage                  |
| **Password Auth**   | ✅ ADDED 2025-12-05            | Safety net enabled                                     |

### Blockers - NONE

1. ~~Fix flake.nix overlays~~ ✅ **FIXED** (same fix as csb1)
2. ~~Validate flake evaluates~~ ✅ **PASS**
3. ~~Add password auth safety net~~ ✅ **DONE**
4. **🟡 PENDING**: Deploy to csb0 with `nixos-rebuild switch`

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

## 📚 Related Documentation

- [SSH Key Security Note](./SSH-KEY-SECURITY-NOTE.md) - Why lib.mkForce
- [Emergency Runbook](../secrets/RUNBOOK.md) - All credentials & procedures
- [csb1 Migration Plan](../../csb1/docs/MIGRATION-PLAN-HOKAGE.md) - Reference (completed 2025-12-05)

---

**STATUS**: ⏳ READY TO DEPLOY - Flake evaluates, password auth enabled
**CONFIDENCE**: 🟢 HIGH - Same pattern as csb1, lessons applied
**NEXT**: Deploy to csb0 with `nixos-rebuild switch`
