# csb0 Hokage Migration (November 2025)

## Status: 🟡 PLANNED

Migration from local mixins (`~/nixcfg/modules/mixins/`) to external Hokage modules (`github:pbek/nixcfg`).

---

## 🚨 Critical: More Complex Than csb1

| Aspect       | csb1 (Done ✅)   | csb0 (This)            |
| ------------ | ---------------- | ---------------------- |
| Services     | Monitoring, docs | **Smart home, IoT**    |
| Impact       | Data gap         | **Garage door broken** |
| Cross-server | Receives MQTT    | **Provides MQTT**      |
| Uptime       | ~200 days        | **267 days**           |
| Users        | Just you         | **Family, neighbors**  |

---

## 📋 Pre-Migration Checklist

- [ ] All health tests pass (T00-T07)
- [ ] Restart safety check passes
- [ ] Restic backup created and verified
- [ ] Netcup snapshot created
- [ ] Live config archived locally
- [ ] configuration.nix ready in main repo
- [ ] Build test passes locally

---

## 🚀 Execution Steps

### Pre-Migration

```bash
# Run all tests
cd hosts/csb0/tests
for f in T*.sh; do ./$f; done

# Safety check
cd ../scripts
./restart-safety.sh

# Create backups
# 1. Restic backup
ssh -p 2222 mba@cs0.barta.cm 'docker exec csb0-restic-cron-hetzner-1 /usr/local/bin/run_backup.sh'

# 2. Archive live config
./01-pre-snapshot.sh
```

### Execute Migration

```bash
ssh -p 2222 mba@cs0.barta.cm
cd ~/nixcfg
git fetch origin && git reset --hard origin/main
sudo nixos-rebuild switch --flake .#csb0
```

### Post-Migration

```bash
./02-post-verify.sh
./03-rollback.sh

# CRITICAL: Verify csb1 still receiving MQTT!
ssh -p 2222 mba@cs1.barta.cm 'docker logs csb1-influxdb-1 --tail 5'
```

---

## 🔄 Rollback

```bash
# Option 1: NixOS rollback
sudo nixos-rebuild switch --rollback

# Option 2: GRUB menu (if SSH broken)
# VNC console → Select previous generation

# Option 3: Netcup snapshot
# SCP panel → Restore snapshot
```

---

## 📚 Related

- [Migration Plan](../../docs/MIGRATION-PLAN-HOKAGE.md)
- [SSH Key Security](../../../../docs/SSH-KEY-SECURITY.md)
- [Runbook](../../secrets/RUNBOOK.md)
- [csb1 Migration](../../../csb1/migrations/2025-11-hokage/README.md) - Reference
