# csb1 Hokage Migration (November 2025)

**CONSOLIDATED EXECUTION DOCUMENT**

Migration from local mixins (`~/nixcfg/modules/mixins/`) to external Hokage modules (`github:pbek/nixcfg`).

## Status: 🟢 READY TO EXECUTE

---

## 🔒 Backups Created (2025-11-29)

| Backup Type           | Status | Details                            | Restore Method       |
| --------------------- | ------ | ---------------------------------- | -------------------- |
| **Netcup Snapshot**   | ✅     | `pre-hokage-migration` @ 11:58:42Z | Netcup SCP → Restore |
| **Restic to Hetzner** | ✅     | Snapshot `fd569a07`, 31 MiB added  | `restic restore`     |
| **Local Archive**     | ✅     | `archive/2025-11-29-pre-hokage/`   | Copy back if needed  |

### Rollback Options (in order of preference)

1. **NixOS Rollback** (fastest): `sudo nixos-rebuild switch --rollback`
2. **GRUB Menu** (if SSH broken): VNC → Select previous generation
3. **Netcup Snapshot** (full disk): SCP panel → Restore snapshot
4. **Restic Backup** (data only): Restore Docker volumes from Hetzner

---

## ✅ Pre-Flight Checks Passed (2025-11-29)

| Check          | Result  | Details               |
| -------------- | ------- | --------------------- |
| Build Test     | ✅ PASS | Config compiles (43s) |
| T00 NixOS Base | ✅ PASS | v24.11, 4 generations |
| T01 Docker     | ✅ PASS | 15 containers healthy |
| T02 Grafana    | ✅ PASS | Dashboard accessible  |
| T03 InfluxDB   | ✅ PASS | 6 months uptime       |
| T04 Traefik    | ✅ PASS | SSL working           |
| T05 Backup     | ✅ PASS | Restic configured     |
| T06 SSH        | ✅ PASS | Hardened, 4 keys      |
| T07 ZFS        | ✅ PASS | 2% used, zstd         |
| Restart Safety | ✅ PASS | All 10 checks green   |

---

## 🎯 What Will Happen

### Services That Will CONTINUE Running

| Service   | How It Survives    | Data Location                           |
| --------- | ------------------ | --------------------------------------- |
| Grafana   | Docker (unchanged) | `/var/lib/docker/volumes/grafana-data`  |
| InfluxDB  | Docker (unchanged) | `/var/lib/docker/volumes/influxdb-data` |
| Docmost   | Docker (unchanged) | `/var/lib/docker/volumes/docmost-data`  |
| Paperless | Docker (unchanged) | `/var/lib/docker/volumes/paperless-*`   |
| Traefik   | Docker (unchanged) | `/home/mba/docker/traefik/`             |
| Hedgedoc  | Docker (unchanged) | `/var/lib/docker/volumes/hedgedoc-*`    |

**Why services survive**: Docker is managed declaratively by NixOS, but the actual containers and volumes live on disk independently. The migration only changes how NixOS is configured, not Docker data.

### What Changes

| Before                                     | After                                         |
| ------------------------------------------ | --------------------------------------------- |
| Local mixins in `~/nixcfg/modules/mixins/` | External hokage from `github:pbek/nixcfg`     |
| `serverMba.enable = true`                  | `hokage.role = "server-remote"`               |
| SSH keys from mixin                        | SSH keys via `lib.mkForce` (explicit)         |
| Implicit sudo config                       | Explicit `sudo-rs.wheelNeedsPassword = false` |

---

## 🚀 Execution Steps

### Pre-Migration (Done ✅)

```bash
# Already completed:
./00-build-test.sh       # ✅ Build verified
./01-pre-snapshot.sh     # ✅ Snapshot captured
# Backups created         # ✅ Netcup + Restic + Archive
```

### Execute Migration

```bash
# 1. SSH to server
ssh -p 2222 mba@cs1.barta.cm

# 2. Update repo (get new configuration)
cd ~/Code/nixcfg
git pull

# 3. Apply migration
sudo nixos-rebuild switch --flake .#csb1

# 4. If successful, verify
nixos-version
docker ps
```

### Post-Migration Verification

```bash
# From your local machine:
./02-post-verify.sh      # Compare with snapshot
./03-rollback.sh         # Verify rollback capability
./04-console-access.sh   # Verify VNC documented
./05-data-integrity.sh   # Check Docker volumes
./06-service-recovery.sh # Check restart policies
./07-firewall-network.sh # Check network access
```

### If Something Goes Wrong

```bash
# Option 1: SSH works - Rollback
sudo nixos-rebuild switch --rollback

# Option 2: SSH broken - VNC
# 1. Netcup SCP → Server → VNC Console
# 2. At GRUB: Select "NixOS - Configuration 4"
# 3. Login locally, run rollback

# Option 3: Restore Netcup Snapshot
# 1. Netcup SCP → Server → Snapshots
# 2. Restore "pre-hokage-migration"
```

---

## 🚨 Critical Configuration Elements

These MUST be in the new `configuration.nix`:

```nix
# 1. SSH KEY OVERRIDE (prevents lockout!)
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABA..." # Your key
  ];
  # Set a known password hash for emergency recovery
  hashedPassword = "$y$j9T$...";  # Generate with: mkpasswd -m yescrypt
};

# 2. PASSWORDLESS SUDO
security.sudo-rs.wheelNeedsPassword = false;

# 3. HOKAGE SETTINGS
hokage = {
  useInternalInfrastructure = false;
  useSecrets = false;
  useSharedKey = false;  # No omega keys!
};

# 4. 🆕 TEMPORARY PASSWORD LOGIN (for migration safety!)
services.openssh.settings.PasswordAuthentication = lib.mkForce true;
```

### ⚠️ hsb1 Lockout Lesson (2025-11-28)

hsb1 migration failed because:

1. Hokage module set SSH keys
2. Our `lib.mkForce` override was applied
3. **But hokage module also disabled password auth**
4. **And our override didn't include password setting**
5. Result: No way to login!

**Fix**: During migration, TEMPORARILY enable password auth as backup:

```nix
# TEMPORARY - Remove after successful migration!
services.openssh.settings.PasswordAuthentication = lib.mkForce true;
```

After verifying SSH key login works, disable password auth again.

---

## 📊 Risk Assessment

| Risk             | Mitigation                                      |
| ---------------- | ----------------------------------------------- |
| SSH lockout      | `lib.mkForce` SSH keys, VNC console ready       |
| Service downtime | Docker data unchanged, ~2 min switch time       |
| Data loss        | 3 independent backups (Netcup, Restic, Archive) |
| Can't rollback   | 4 NixOS generations, tested rollback            |

**Confidence Level**: 🟢 HIGH

---

## 📚 Related Documentation

- [Full Migration Plan](../../docs/MIGRATION-PLAN-HOKAGE.md) - Detailed explanation
- [SSH Key Security Note](../../docs/SSH-KEY-SECURITY-NOTE.md) - Why lib.mkForce
- [Emergency Runbook](../../secrets/RUNBOOK.md) - All credentials & procedures
- [Old Config Archive](../../archive/2025-11-29-pre-hokage/) - Pre-migration reference
