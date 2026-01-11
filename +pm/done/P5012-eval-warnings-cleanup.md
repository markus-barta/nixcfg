# P5012: Evaluation Warnings & Deprecation Cleanup

**Created**: 2026-01-11  
**Priority**: 🟢 LOW  
**Status**: 🟡 IN_PROGRESS

## ⚠️ Summary

Consolidated tracking for Nix evaluation warnings, deprecated options, and legacy files identified during the January 2026 audits.

## 🛠️ Issues & Fixes

- [x] **User Password Ambiguity**: User `mba` has multiple password options (`hashedPassword` vs `initialHashedPassword`).
  - _Fix_: Forced `initialHashedPassword = null` in `hsb0`, `hsb1`, and `csb0`.
- [x] **Service Dependency Mismatch**: `child-keyboard-fun.service` missing dependency on `network-online.target`.
  - _Fix_: Added `wants` in `common.nix`.
- [ ] **System/HostPlatform Renaming**: `system` option is deprecated, use `nixpkgs.hostPlatform`.
  - _Research_: The warning triggers when `nixpkgs.system` is assigned. In Flakes, this should be replaced with `nixpkgs.hostPlatform = "..."`.
  - _Plan_: Audit `flake.nix` and ensuring no imported modules (like `hokage`) are setting the legacy option. If they are, use `lib.mkForce` or `lib.mkOverride` to point to the modern option.
- [ ] **Zsh Deprecation**: `programs.zsh.initExtra` migration to `initContent` (imac0).
- [ ] **Uzumaki Legacy Cleanup**: Delete abandoned shim files from the December restructure (formerly [[P7100]]).

## 🛠️ To-Do

- [ ] Audit `flake.nix` for `system = ...` assignments and migrate to `nixpkgs.hostPlatform`.
- [ ] Delete deprecated Uzumaki files:
  - `modules/uzumaki/fish/fish-config.nix` (shim)
  - `modules/uzumaki/home.nix` (legacy)
  - `modules/uzumaki/server.nix` (legacy)
- [ ] Verify `imac0` switch warnings after Zsh cleanup.

## 🔗 References

- Replaces: [[P6400]], [[P7100]]
- Discovery: [[P5010-ncps-migration-error]]
