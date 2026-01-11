# P5011: NCPS Version Pin Tracking & Technical Debt

**Created**: 2026-01-11  
**Priority**: 🔥 HIGH  
**Status**: 🟡 PENDING

## ⚠️ Problem Statement

We are currently pinning `ncps` to commit `ff083aff` because:

1.  **Regression**: Latest `ncps` (v0.6.0+) changed migration directory structures, breaking the current NixOS module's `ExecStartPre` script.
2.  **Dependency Conflict**: Newer versions require Go 1.25.5, which is currently unavailable/conflicting in our nixpkgs channel (see [[P8200-nixpkgs-go-1.25.5-upgrade]]).

Pinned inputs are "invisible debt" that prevent security updates and feature parity.

## 🛠️ Proposed Actions

- [ ] **Option A: Fix & Upgrade**: Patch the `ncps` NixOS module to support the new `migrations/<db_type>` directory structure.
- [ ] **Option B: Start Fresh / Containerize**: Remove the native NixOS module and move `ncps` to a Docker container (consistent with other Tier 1 services on `hsb0`/`hsb1`). This would allow using the official upstream container which bundles migrations correctly.
- [ ] **Option C: Deprecate**: Evaluate if `ncps` is still required or if `attic` or local `nix-serve` is a better fit for our current fleet size.

## 🛠️ To-Do

- [ ] Verify if Go 1.25.5 is available in `nixos-unstable` yet.
- [ ] Evaluate the difficulty of patching the migration script vs. containerizing.
- [ ] If containerizing: Move data to `/var/lib/ncps/data` and update `docker-compose.yml`.

## 🔗 References

- Fix Incident: [[P5010-ncps-migration-error]]
- Go Upgrade Block: [[P8200-nixpkgs-go-1.25.5-upgrade]]
- Original Project: [[P5000-ncps-binary-cache-proxy]]
