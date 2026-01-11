# P5013: Investigation: Persistent 'system' Deprecation Warning

**Created**: 2026-01-11  
**Priority**: 🔥 HIGH (Technical Debt)  
**Status**: ✅ COMPLETED

## ⚠️ Problem Statement

Despite multiple attempts to migrate to modern NixOS patterns, the following evaluation warning persists during builds:
`evaluation warning: 'system' has been renamed to/replaced by 'stdenv.hostPlatform.system'`

## 🔍 Investigation Log

### 1. Research Conducted

- **Upstream Release Notes**: Confirmed that `nixpkgs.system` was deprecated in NixOS 25.05 in favor of `nixpkgs.hostPlatform`.
- **Grok Analysis**: Clues suggested that reading `pkgs.system` (not just setting it) triggers the warning in post-25.05 Nixpkgs.

### 2. Resolution (2026-01-11)

The warnings were triggered by local read-access to the deprecated `pkgs.system` alias in several configuration files.

**Changes made:**

1.  **Renamed `system` variable** in `flake.nix` to `linuxSystem` to avoid shadowing and clarify intent.
2.  **Replaced `${pkgs.system}`** with `${pkgs.stdenv.hostPlatform.system}` in:
    - `hosts/hsb0/configuration.nix`
    - `hosts/hsb8/configuration.nix`
    - `devenv.nix`
3.  **Updated `flake.nix` overlays** to use `final.stdenv.hostPlatform.system`.

**Verification**:

- `nix eval .#nixosConfigurations.hsb0.config.system.build.toplevel` -> ✅ No warnings.
- `nix eval .#nixosConfigurations.hsb1.config.system.build.toplevel` -> ✅ No warnings.

## 🛠️ To-Do (Archived)

- [x] Run evaluation with `--show-trace` to pinpoint exactly which file/line accesses the deprecated attribute.
- [x] Rename the local `system` variable in `flake.nix` to rule out naming collisions.

## 🔗 References

- Consolidated Fixes: [[P5012-eval-warnings-cleanup]]
- Research Source: [NixOS Discourse - system vs hostPlatform](https://discourse.nixos.org/t/how-to-fix-evaluation-warning-system-has-been-renamed-to-replaced-by-stdenv-hostplatform-system/72120)
