# 2025-11-29 - Cleanup secrets/ Directory

## ✅ COMPLETED: 2025-12-06

This cleanup was completed as part of the pbek → markus nixcfg transition.

## What Was Done

### Phase 1: Archive Legacy Secrets ✅

Moved 10 unused `.age` files to `secrets/archived/`:

- `id_ecdsa_sk.age` - Yubikey SSH key (no Yubikey)
- `nixpkgs-review.age` - nixpkgs workflow (not used)
- `github-token.age` - Using `~/.secrets/github-token` instead
- `neosay.age` - Matrix notifications (not configured)
- `atuin.age` - Shell history (disabled in common.nix)
- `qc-config.age` - QOwnNotes CLI (not used)
- `secret1.age` - Test file
- `pia-user.age`, `pia-pass.age`, `pia.age` - PIA VPN (archived for future use)

### Phase 2: Clean Up secrets.nix ✅

Removed 15 legacy host/user keys:

- `agenix` - pbek's editing key
- `eris`, `neptun`, `pluto`, `jupiter`, `gaia`, `venus`, `astra`, `caliban`, `sinope`, `rhea`, `hyperion`, `mercury` - pbek's old hosts
- `general` - Shared legacy keys

Kept only active keys:

- `markus` - Personal key for editing secrets
- `gb` - User on hsb8
- `hsb0`, `hsb8` - Active host keys

### Phase 3: Documentation ✅

Created `secrets/archived/README.md` explaining:

- What each archived file was for
- Why it was archived
- How to restore if needed in the future

## Current State

### Active Secrets (3 files)

| File                     | Used By | Purpose                         |
| ------------------------ | ------- | ------------------------------- |
| `static-leases-hsb0.age` | hsb0    | AdGuard DHCP static leases      |
| `static-leases-hsb8.age` | hsb8    | AdGuard DHCP static leases      |
| `mqtt-hsb0.age`          | hsb0    | UPS monitoring MQTT credentials |

### Active Keys (4 entries)

| Key      | Type | Purpose                               |
| -------- | ---- | ------------------------------------- |
| `markus` | User | Edit all secrets with `~/.ssh/id_rsa` |
| `gb`     | User | Access hsb8 secrets                   |
| `hsb0`   | Host | Decrypt secrets on hsb0               |
| `hsb8`   | Host | Decrypt secrets on hsb8               |

## Verification

```bash
# Builds still work
nix eval '.#nixosConfigurations.hsb0.config.system.build.toplevel.drvPath'  # ✅
nix eval '.#nixosConfigurations.hsb8.config.system.build.toplevel.drvPath'  # ✅
```

## Future Work

- Add csb0/csb1 host keys when they need secrets
- Configure PIA VPN (files archived, ready when needed)
