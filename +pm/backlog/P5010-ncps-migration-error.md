# P5010: NCPS Migration Error Investigation (hsb0)

**Created**: 2026-01-11  
**Priority**: MEDIUM  
**Status**: 🟢 RESOLVED

## ⚠️ Incident Overview

During the Tier 1 Backup Audit (P9100), `hsb0` experienced an activation failure. While core services recovered, `ncps.service` remains in a failed state.

### Error Details

```text
ncps-pre-start: Error: no migration files found
```

The service exits with `status=2/INVALIDARGUMENT`.

## 🛠️ Resolution

- **Fix**: Pinned `ncps` flake input to `ff083aff` in `flake.nix`.
- **Reason**: Upstream `ncps` v0.6.0+ changed the migration file structure (nested under subdirectories like `sqlite/`), which the current NixOS module doesn't handle in its `ExecStartPre` script. Reverting to the last known-good commit restores the old structure.
- **Verification**: `ncps.service` is now active and healthy on `hsb0`.

## 🛠️ To-Do

- [x] Inspect the `ncps` derivation to see where migration files are stored.
- [x] Verify if a `nix flake update` caused the regression.
- [x] Test a rollback of the NCPS flake input.
- [ ] Monitor upstream for a fix to the NixOS module to support multi-DB migration paths.

## 🔗 References

- Parent Project: [[P5000-ncps-binary-cache-proxy]]
- Audit Project: [[P9100-hsb0-hsb1-backup-audit]]
