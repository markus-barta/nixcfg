# csb1 Hokage Migration (November 2025)

Migration from local mixins to external Hokage modules (`github:pbek/nixcfg`).

## Status: 🟡 Planned

## Scripts

Run in order:

| #   | Script                   | Purpose                                    |
| --- | ------------------------ | ------------------------------------------ |
| 00  | `00-build-test.sh`       | Build new config WITHOUT applying          |
| 01  | `01-pre-snapshot.sh`     | Capture system state before migration      |
| 02  | `02-post-verify.sh`      | Compare post-migration state with snapshot |
| 03  | `03-rollback.sh`         | Verify rollback capability                 |
| 04  | `04-console-access.sh`   | Verify VNC/emergency access                |
| 05  | `05-data-integrity.sh`   | Check data volumes and configs             |
| 06  | `06-service-recovery.sh` | Verify service restart policies            |
| 07  | `07-firewall-network.sh` | Verify network/firewall rules              |

## Execution Order

### Before Migration

```bash
./00-build-test.sh      # Verify build succeeds (no changes applied)
./01-pre-snapshot.sh    # Creates snapshot in snapshots/
```

### Apply Migration

```bash
# On csb1:
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#csb1
```

### After Migration

```bash
./02-post-verify.sh     # Compares with pre-migration snapshot
./03-rollback.sh        # Verify rollback works
./04-console-access.sh  # Verify emergency access
./05-data-integrity.sh  # Check data survived
./06-service-recovery.sh
./07-firewall-network.sh
```

### If Problems

```bash
# Via SSH (if working):
sudo nixos-rebuild switch --rollback

# Via VNC (if SSH broken):
# 1. Netcup SCP → VNC Console
# 2. GRUB menu → Select previous generation
```

## Snapshots

Pre-migration snapshots are stored in `snapshots/`:

- System info, Docker state, ZFS, security settings
- Used by `02-post-verify.sh` for comparison

## Related Documentation

- `../../docs/MIGRATION-PLAN-HOKAGE.md` - Full migration plan
- `../../docs/SSH-KEY-SECURITY-NOTE.md` - Critical SSH key override
- `../../secrets/RUNBOOK.md` - Emergency procedures with credentials
