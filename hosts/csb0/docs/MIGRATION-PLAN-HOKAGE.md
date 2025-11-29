# csb0 → External Hokage Consumer Migration Plan

**Server**: csb0 (Cloud Server Barta 0)
**Migration Type**: External Hokage Consumer Pattern
**Risk Level**: 🟠 **MEDIUM-HIGH** - Smart home & IoT critical services
**Status**: 🟡 **PLANNED** - After csb1 success
**Created**: November 29, 2025
**Last Updated**: November 29, 2025

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

## ✅ Lessons Learned from csb1 (2025-11-29)

### What Worked

1. **`lib.mkForce` for SSH keys** - Essential to block omega key injection
2. **Temporary password auth** - Critical safety net during migration
3. **Node-RED/hsb1 SSH key** - Must include for automation
4. **Full reboot test** - Validates GRUB and boot sequence
5. **Multiple backups** - Netcup snapshot + Restic + Archive

### What to Apply

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

## 📊 Risk Assessment

| Risk                  | Mitigation                            |
| --------------------- | ------------------------------------- |
| SSH lockout           | `lib.mkForce` SSH keys, password auth |
| Smart home downtime   | Quick switch (~2 min), test all flows |
| MQTT broker down      | csb1 can buffer, data gap acceptable  |
| Garage door broken    | Test Telegram bot immediately         |
| Backup manager broken | Verify cleanup runs next day          |
| Cross-server impact   | Test csb1 MQTT connection after       |

**Confidence Level**: 🟢 HIGH (after csb1 success)

---

## 📚 Related Documentation

- [SSH Key Security Note](./SSH-KEY-SECURITY-NOTE.md) - Why lib.mkForce
- [Emergency Runbook](../secrets/RUNBOOK.md) - All credentials & procedures
- [csb1 Migration](../../csb1/migrations/2025-11-hokage/README.md) - Lessons learned
