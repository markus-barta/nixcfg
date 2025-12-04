# Module Architecture - Current State

> 📊 **Flowchart:** See [architecture-current.mermaid](./architecture-current.mermaid)

## Legend

| Color     | Meaning                            |
| --------- | ---------------------------------- |
| 🔵 Blue   | Entry point / flake.nix            |
| 🔴 Red    | External module (hokage from pbek) |
| 🟢 Green  | Core shared config (common.nix)    |
| 🟡 Yellow | Uzumaki modules (local)            |
| 🟣 Purple | Theme system                       |

## Data Flow Summary

### NixOS Servers (hsb0, hsb1, hsb8, csb0, csb1)

```text
flake.nix
    ├── commonServerModules (HM + common.nix + overlays + agenix)
    ├── hokage (external module)
    ├── host configuration.nix
    │       ├── uzumaki/server.nix → common.nix (fish functions)
    │       └── stasysmo/nixos.nix (system metrics)
    └── common.nix
            ├── fish-config.nix (aliases/abbrs)
            └── home-manager users
                    └── theme-hm.nix → theme-palettes.nix
```

### NixOS Desktop (gpc0)

```text
flake.nix
    ├── home-manager + plasma-manager (inline, NOT commonServerModules)
    ├── hokage (external module)
    ├── common.nix (loads AFTER hokage to override)
    └── host configuration.nix
            ├── uzumaki/desktop.nix → common.nix (fish functions)
            └── stasysmo/nixos.nix (system metrics)
```

### macOS (imac0, imac-mba-work)

```text
flake.nix → mkDarwinHome(hostname)
    └── homeManagerConfiguration
            └── host home.nix
                    ├── theme-hm.nix (per-host colors)
                    ├── uzumaki/macos.nix → common.nix (fish functions)
                    └── stasysmo/home-manager.nix (launchd)
```

## Current Module Inventory

| File                                       | Type                  | Platform | What It Provides                                  |
| ------------------------------------------ | --------------------- | -------- | ------------------------------------------------- |
| `modules/common.nix`                       | NixOS module          | NixOS    | Fish setup, packages, HM config, timezone, locale |
| `modules/uzumaki/common.nix`               | Attribute set         | Both     | Fish function definitions (pingt, stress, etc.)   |
| `modules/uzumaki/server.nix`               | NixOS config fragment | NixOS    | Fish interactiveShellInit, zellij package         |
| `modules/uzumaki/desktop.nix`              | NixOS config fragment | NixOS    | Same as server.nix (identical!)                   |
| `modules/uzumaki/macos.nix`                | HM config fragment    | macOS    | programs.fish.functions via inherit               |
| `modules/uzumaki/macos-common.nix`         | Attribute set         | macOS    | fishConfig, weztermConfig, commonPackages         |
| `modules/shared/fish-config.nix`           | Attribute set         | Both     | fishAliases, fishAbbrs                            |
| `modules/shared/theme-hm.nix`              | HM module             | Both     | Per-host Starship, Zellij, Eza theming            |
| `modules/shared/theme-palettes.nix`        | Attribute set         | Both     | Color palette definitions                         |
| `modules/shared/stasysmo/nixos.nix`        | NixOS module          | NixOS    | systemd service for metrics                       |
| `modules/shared/stasysmo/home-manager.nix` | HM module             | macOS    | launchd daemon for metrics                        |

## Host Import Matrix

| Host          | common.nix  | uzumaki/server | uzumaki/desktop | uzumaki/macos | theme-hm       | stasysmo |
| ------------- | ----------- | -------------- | --------------- | ------------- | -------------- | -------- |
| hsb0          | ✓ (via CSM) | ✓              | -               | -             | ✓ (via common) | ✓        |
| hsb1          | ✓ (via CSM) | ✓              | -               | -             | ✓ (via common) | ✓        |
| hsb8          | ✓ (via CSM) | ✓              | -               | -             | ✓ (via common) | ✓        |
| csb0          | ✓ (via CSM) | ✓              | -               | -             | ✓ (via common) | ✓        |
| csb1          | ✓ (via CSM) | ✓              | -               | -             | ✓ (via common) | ✓        |
| gpc0          | ✓ (inline)  | -              | ✓               | -             | ✓ (via common) | ✓        |
| imac0         | -           | -              | -               | ✓             | ✓ (direct)     | ✓        |
| imac-mba-work | -           | -              | -               | ✓             | ✓ (direct)     | ✓        |

**CSM** = commonServerModules (includes common.nix)

## Known Issues

1. **uzumaki is not a real module** - No `default.nix`, no options, just files that get imported
2. **Different patterns for NixOS vs macOS** - server.nix uses interactiveShellInit, macos.nix uses programs.fish.functions
3. **gpc0 has special handling** - Doesn't use commonServerModules, loads common.nix after hokage
4. **String interpolation hacks** - Fish functions are converted to strings via mkFishFunction helper
5. **No single entry point** - Each host must know which uzumaki file to import
