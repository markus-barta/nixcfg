# 2025-12-01 - Create Standalone pingt Package

## Status: ✅ COMPLETE (2025-12-07)

## Description

Create a standalone Nix package for the `pingt` command (timestamped ping with color-coded output).

## Implementation

### Package Location

`pkgs/pingt/` containing:

- `pingt.sh` - Pro-level bash script
- `default.nix` - Nix package definition

### Features

- ✅ Cross-shell compatible (bash/zsh/fish/sh)
- ✅ Color-coded output (yellow=timeout, red=error, gray=timestamp)
- ✅ Respects `NO_COLOR` environment variable
- ✅ Proper `--help` and `--version` flags
- ✅ Works on Linux (iputils) and macOS (system ping)
- ✅ Full meta (description, license MIT, maintainer)
- ✅ Integrated into uzumaki module (auto-installed)

### Integration

- Added to `flake.nix` packages (x86_64-linux, x86_64-darwin, aarch64-darwin)
- Added overlay `overlays-local` for `pkgs.pingt`
- Auto-installed via `modules/uzumaki/default.nix` (NixOS)
- Auto-installed via `modules/uzumaki/home-manager.nix` (macOS)

## Test Results (imac0 - 2025-12-07)

```
$ pingt --version
pingt 1.0.0

$ pingt -c 2 google.com
11:35:19 · PING google.com (142.251.39.14): 56 data bytes
11:35:19 · 64 bytes from 142.251.39.14: icmp_seq=0 ttl=118 time=40.890 ms
11:35:20 · 64 bytes from 142.251.39.14: icmp_seq=1 ttl=118 time=40.406 ms
```

## Acceptance Criteria

- [x] Create package definition in `pkgs/pingt/`
- [x] Package provides `pingt` command
- [x] Maintains current functionality (timestamped ping with color-coded output)
- [x] Works on both Linux and macOS
- [x] Update uzumaki modules to auto-install the package
- [x] Test on imac0 (macOS)
- [x] Document the package

## Notes

- Fish function `pingt` still exists in `functions.nix` (takes precedence in fish shell)
- Bash package used in bash/zsh/other shells
- Ready for pbek to use in pbek-nixcfg

---

## 📦 For pbek: How to Use pingt in pbek-nixcfg

### Option A: Add as Flake Input (Recommended)

```nix
# In flake.nix, add to inputs:
inputs = {
  # ... existing inputs ...

  # Markus' nixcfg - provides pingt package
  mba-nixcfg = {
    url = "github:markus-barta/nixcfg";
    inputs.nixpkgs.follows = "nixpkgs";  # Use same nixpkgs
  };
};
```

Then use in your modules:

```nix
# In any NixOS module (e.g., modules/hokage/common.nix)
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.mba-nixcfg.packages.${pkgs.system}.pingt
  ];
}
```

Or for Home Manager:

```nix
# In home-manager config
{ inputs, pkgs, ... }:
{
  home.packages = [
    inputs.mba-nixcfg.packages.${pkgs.system}.pingt
  ];
}
```

### Option B: Copy the Package (Self-Contained)

Copy these files to `pkgs/pingt/` in pbek-nixcfg:

1. `pkgs/pingt/default.nix`
2. `pkgs/pingt/pingt.sh`

Then add to your overlay:

```nix
# In overlays or flake.nix
final: prev: {
  pingt = final.callPackage ./pkgs/pingt { };
}
```

### What pingt Does

```bash
# Timestamped ping with color-coded output
pingt google.com

# Output:
# 11:35:19 · PING google.com: 56 data bytes
# 11:35:19 · 64 bytes from google.com: icmp_seq=0 ttl=118 time=40ms  # normal
# 11:35:20 · Request timeout for icmp_seq=1                          # yellow
# 11:35:21 · sendto: No route to host                                # red
```

### Features

- ✅ Works in fish, bash, zsh, sh
- ✅ Timestamps on every line (HH:MM:SS)
- ✅ Yellow for timeouts, red for errors
- ✅ Respects NO_COLOR env var
- ✅ --help and --version flags
- ✅ Works on Linux and macOS
