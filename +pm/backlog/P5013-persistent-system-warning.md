# P5013: Investigation: Persistent 'system' Deprecation Warning

**Created**: 2026-01-11  
**Priority**: 🔥 HIGH (Technical Debt)  
**Status**: 🔴 STUCK / BLOCKED

## ⚠️ Problem Statement

Despite multiple attempts to migrate to modern NixOS patterns, the following evaluation warning persists during builds:
`evaluation warning: 'system' has been renamed to/replaced by 'stdenv.hostPlatform.system'`

## 🔍 Investigation Log

### 1. Research Conducted

- **Upstream Release Notes**: Confirmed that `nixpkgs.system` was deprecated in NixOS 25.05 in favor of `nixpkgs.hostPlatform`.
- **Discourse/GitHub**: Verified that this warning is specifically triggered when `config.nixpkgs.system` is assigned a value in a module.
- **Nixpkgs Internal Logic**: The warning is generated in `nixpkgs/pkgs/top-level/all-packages.nix` when the legacy attribute is accessed or set.

### 2. Reasoning

- **Assumption**: The warning was caused by our own `flake.nix` or host configurations using `nixpkgs.system`.
- **Hypothesis**: Replacing `nixpkgs.system` with `nixpkgs.hostPlatform` would silence the warning.
- **Discovery**: Standalone Home Manager (macOS) does not support `nixpkgs.hostPlatform`, causing evaluation errors when applied globally.

### 3. Changes Attempted

- **Attempt 1**: Audit `hosts/` for `nixpkgs.system`. Found none explicitly set.
- **Attempt 2**: Updated `commonServerModules` in `flake.nix` to use `nixpkgs.hostPlatform = system;`.
- **Attempt 3**: Attempted to add `nixpkgs.hostPlatform` to the `mkDarwinHome` helper. Result: **Failed** (Option does not exist in standalone HM).
- **Attempt 4**: Consolidated logic in `common.nix` and checked for `system =` assignments.

### 4. Why it still doesn't work (Analysis)

The warning likely persists for one of the following reasons:

1.  **Upstream Modules**: We import `inputs.nixcfg.nixosModules.hokage` and `plasma-manager.homeModules.plasma-manager`. If either of these upstream modules sets `nixpkgs.system`, it triggers the warning in _our_ evaluation.
2.  **Implicit Access**: Some internal Nixpkgs logic might be accessing `system` in a way that triggers the warning when certain overlays or cross-compilation settings are present.
3.  **Naming Collision**: We use a local variable `let system = "x86_64-linux";` in `flake.nix`. While this is just a string, passing it into certain functions might be causing an implicit assignment to the deprecated Nixpkgs attribute.

## 🛠️ To-Do

- [ ] Run evaluation with `--show-trace` and `--verbose` to pinpoint exactly which file/line accesses the deprecated attribute.
- [ ] Test a build with `hokage` module disabled to see if the warning disappears.
- [ ] Rename the local `system` variable in `flake.nix` to `hostArch` or similar to rule out naming collisions.

## 🔗 References

- Consolidated Fixes: [[P5012-eval-warnings-cleanup]]
- Research Source: [NixOS Discourse - system vs hostPlatform](https://discourse.nixos.org/t/how-to-fix-evaluation-warning-system-has-been-renamed-to-replaced-by-stdenv-hostplatform-system/72120)
