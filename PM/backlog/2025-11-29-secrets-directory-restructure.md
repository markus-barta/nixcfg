# 2025-11-29 - Cleanup secrets/ Directory

## Description

The `secrets/` directory contains legacy secrets and host keys from the old pbek/nixcfg structure that are no longer used. This cleanup removes unused items and documents the structure.

## Analysis Results

### Secrets Files Inventory

| File                     | Status        | Used By                            |
| ------------------------ | ------------- | ---------------------------------- |
| `static-leases-hsb0.age` | ✅ **ACTIVE** | hsb0/configuration.nix             |
| `static-leases-hsb8.age` | ✅ **ACTIVE** | hsb8/configuration.nix             |
| `id_ecdsa_sk.age`        | ❌ **LEGACY** | Only in archived pre-hokage mixins |
| `nixpkgs-review.age`     | ❌ **LEGACY** | Only in archived pre-hokage mixins |
| `pia-user.age`           | ❌ **LEGACY** | Only in archived pre-hokage mixins |
| `pia-pass.age`           | ❌ **LEGACY** | Only in archived pre-hokage mixins |
| `pia.age`                | ❌ **LEGACY** | Unknown, no references found       |
| `github-token.age`       | ❌ **LEGACY** | Only in archived pre-hokage mixins |
| `neosay.age`             | ❌ **LEGACY** | Unknown, no active references      |
| `atuin.age`              | ❌ **LEGACY** | Unknown, no active references      |
| `qc-config.age`          | ❌ **LEGACY** | Unknown, no active references      |
| `secret1.age`            | ❌ **LEGACY** | Test file, not used                |

### Host Keys in secrets.nix

| Key        | Status    | Notes                            |
| ---------- | --------- | -------------------------------- |
| `agenix`   | ✅ Keep   | System key for editing secrets   |
| `hsb0`     | ✅ Keep   | Active home server               |
| `hsb8`     | ✅ Keep   | Active home server               |
| `markus`   | ✅ Keep   | Personal user key                |
| `gb`       | ✅ Keep   | User on hsb8                     |
| `general`  | ⚠️ Review | May be needed for shared secrets |
| `eris`     | ❌ Delete | Only in `hosts/archived/`        |
| `neptun`   | ❌ Delete | Only in `hosts/archived/`        |
| `pluto`    | ❌ Delete | Only in `hosts/archived/`        |
| `jupiter`  | ❌ Delete | Only in `hosts/archived/`        |
| `gaia`     | ❌ Delete | Only in `hosts/archived/`        |
| `venus`    | ❌ Delete | Only in `hosts/archived/`        |
| `astra`    | ❌ Delete | Only in `hosts/archived/`        |
| `caliban`  | ❌ Delete | Only in `hosts/archived/`        |
| `sinope`   | ❌ Delete | Only in `hosts/archived/`        |
| `rhea`     | ❌ Delete | Only in `hosts/archived/`        |
| `hyperion` | ❌ Delete | Only in `hosts/archived/`        |
| `mercury`  | ❌ Delete | Only in `hosts/archived/`        |

### Planned Secrets (from other backlog items)

| File               | For  | Status                                         |
| ------------------ | ---- | ---------------------------------------------- |
| `mqtt-hsb1.age`    | hsb1 | Planned in `2025-12-01-hsb1-agenix-secrets.md` |
| `tapo-c210-00.age` | hsb1 | Planned in `2025-12-01-hsb1-agenix-secrets.md` |

## Acceptance Criteria

### Part 1: Remove Legacy Host Keys

- [ ] Remove all 12 legacy host keys from `secrets.nix` (eris, neptun, pluto, jupiter, gaia, venus, astra, caliban, sinope, rhea, hyperion, mercury)
- [ ] Remove `systems` variable that aggregates legacy keys
- [ ] Update any secrets that reference `systems` to use explicit keys

### Part 2: Archive Legacy Secrets

- [ ] Move unused `.age` files to `secrets/archived/`
- [ ] Files to archive: `id_ecdsa_sk.age`, `nixpkgs-review.age`, `pia-*.age`, `github-token.age`, `neosay.age`, `atuin.age`, `qc-config.age`, `secret1.age`
- [ ] Create `secrets/archived/README.md` explaining these are legacy

### Part 3: Document Structure

- [ ] Update or create `secrets/README.md` documenting:
  - How to add new secrets
  - Which hosts have which secrets
  - Key naming conventions

## Test Plan

### Manual Test

1. After cleanup, verify builds still work:
   ```bash
   nixos-rebuild build --flake .#hsb0
   nixos-rebuild build --flake .#hsb8
   ```
2. Verify active secrets still decrypt on hosts

### Automated Test

```bash
# Verify only expected files remain in secrets/
ls secrets/*.age | wc -l
# Expected: 2 (static-leases-hsb0.age, static-leases-hsb8.age)

# Verify secrets.nix doesn't reference legacy hosts
grep -E "(eris|neptun|pluto|jupiter|gaia|venus|astra|caliban|sinope|rhea|hyperion|mercury)" secrets/secrets.nix
# Expected: no output
```

## Summary

**Before**: 13 secrets files, 17 host keys (most unused)
**After**: 2 active secrets + archived legacy, 6 host keys

This is a cleanup task, not a restructure. The goal is to remove cruft from the old pbek/nixcfg structure.
