# csb1 Hokage Migration (November 2025)

## Status: ✅ COMPLETE (2025-11-29)

Migration from local mixins (`~/nixcfg/modules/mixins/`) to external Hokage modules (`github:pbek/nixcfg`).

---

## 🎉 Migration Summary

| Milestone              | Time  | Status |
| ---------------------- | ----- | ------ |
| Pre-flight checks      | 10:50 | ✅     |
| Backups created        | 11:58 | ✅     |
| Configuration deployed | 13:43 | ✅     |
| Services restarted     | 13:44 | ✅     |
| Full reboot verified   | 13:54 | ✅     |
| Password auth disabled | 14:00 | ✅     |

### Final Configuration

- **NixOS Version**: 25.11.20251117.89c2b23 (Xantusia)
- **Generation**: 5
- **Docker Containers**: 15 running
- **SSH Keys**: mba + hsb1 (omega blocked via `lib.mkForce`)
- **Rollback Available**: Yes (generations 1-4)

---

## 🔒 Backups Available

| Backup Type           | Details                            | Restore Method       |
| --------------------- | ---------------------------------- | -------------------- |
| **Netcup Snapshot**   | `pre-hokage-migration` @ 11:58:42Z | Netcup SCP → Restore |
| **Restic to Hetzner** | Snapshot `fd569a07`, 31 MiB added  | `restic restore`     |
| **Local Archive**     | `archive/2025-11-29-pre-hokage/`   | Copy back if needed  |

---

## ✅ Post-Migration Verification

| Test              | Result               |
| ----------------- | -------------------- |
| SSH key auth      | ✅ Working           |
| Passwordless sudo | ✅ Working           |
| No omega keys     | ✅ 0 found           |
| Docker containers | ✅ 15/15 running     |
| Grafana           | ✅ HTTP 200          |
| Docmost           | ✅ HTTP 200          |
| ZFS pool          | ✅ Healthy (3% used) |
| **Full reboot**   | ✅ Clean startup     |

---

## 📝 Lessons Learned

### hsb1 Lockout (2025-11-28)

The hsb1 migration taught us to:

1. **Always use `lib.mkForce`** for SSH keys to override hokage injection
2. **Temporarily enable password auth** during migration as safety net
3. **Have VNC console ready** before any config changes
4. **Test reboot** after migration to verify GRUB/boot works

### What Worked Well

- Pre-migration snapshot (Netcup) provided peace of mind
- Node-RED SSH key (hsb1/miniserver24) was correctly preserved
- Docker data survived seamlessly (as expected)
- Rollback generations available if needed

---

## 📚 Reference

- [Migration Plan](../../docs/MIGRATION-PLAN-HOKAGE.md) - Full details
- [SSH Key Security](../../docs/SSH-KEY-SECURITY-NOTE.md) - Why lib.mkForce
- [Emergency Runbook](../../secrets/RUNBOOK.md) - Credentials & procedures
- [Old Config Archive](../../archive/2025-11-29-pre-hokage/) - Pre-migration reference
