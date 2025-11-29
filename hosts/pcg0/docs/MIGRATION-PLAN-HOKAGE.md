# pcg0 → External Hokage Consumer Migration Plan

**Host**: pcg0 (Gaming PC 0, formerly mba-gaming-pc)  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🟢 **LOW** - Desktop system, can test locally  
**Status**: 🔄 **IN PROGRESS**  
**Created**: November 29, 2025

---

## 🎯 Migration Overview

### Current State

| Attribute       | Value                                            |
| --------------- | ------------------------------------------------ |
| **Hostname**    | `pcg0`                                           |
| **Role**        | Gaming desktop with KDE Plasma                   |
| **Criticality** | 🟢 **LOW** - Personal gaming PC                  |
| **OS**          | NixOS (unstable)                                 |
| **Structure**   | Local hokage module (`../../modules/hokage`)     |
| **Pattern**     | `mkDesktopHost` helper with commonDesktopModules |
| **Users**       | `mba` (primary), `omega` (Patrizio)              |

### Target State

| Attribute     | Value                                                    |
| ------------- | -------------------------------------------------------- |
| **Structure** | External hokage from `github:pbek/nixcfg`                |
| **Pattern**   | Explicit module list with commonDesktopModules           |
| **Uzumaki**   | Local `../../modules/uzumaki/desktop.nix` (kept)         |
| **Nixbit**    | Override to `https://github.com/markus-barta/nixcfg.git` |

---

## 🔄 What's Changing

### From (Current - Local Hokage)

```nix
# flake.nix
pcg0 = mkDesktopHost "pcg0" [ disko.nixosModules.disko ];

# hosts/pcg0/configuration.nix
imports = [
  ./hardware-configuration.nix
  ./disk-config.zfs.nix
  ../../modules/hokage              # ← LOCAL hokage
  ../../modules/uzumaki/desktop.nix
];
```

### To (Target - External Hokage Consumer)

```nix
# flake.nix
pcg0 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonDesktopModules ++ [
    inputs.nixcfg.nixosModules.hokage  # ← EXTERNAL hokage
    ./hosts/pcg0/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // { inherit inputs; };
};

# hosts/pcg0/configuration.nix
imports = [
  ./hardware-configuration.nix
  ./disk-config.zfs.nix
  ../../modules/uzumaki/desktop.nix  # ← Local Uzumaki (kept)
];

hokage = {
  # ... existing config ...
  programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
};
```

---

## 📋 Migration Checklist

### Pre-Migration

- [x] Rename host from `mba-gaming-pc` to `pcg0`
- [ ] Backup current working configuration
- [ ] Document current hokage settings

### Migration Steps

- [ ] Update `flake.nix` to use external hokage for pcg0
- [ ] Update `configuration.nix` to remove local hokage import
- [ ] Add `hokage.programs.nixbit.repository` override
- [ ] Keep `omega` user definition as-is
- [ ] Keep local Uzumaki desktop module

### Global Changes (All Hosts)

- [ ] Add `nixbit.repository` override to hsb0
- [ ] Add `nixbit.repository` override to hsb1
- [ ] Add `nixbit.repository` override to hsb8
- [ ] Add `nixbit.repository` override to csb0
- [ ] Add `nixbit.repository` override to csb1

### Post-Migration

- [ ] Run `nix flake check`
- [ ] Test build: `nixos-rebuild build --flake .#pcg0`
- [ ] Deploy on actual hardware when available

---

## 🔑 Key Differences from Server Migration

| Aspect             | Server (hsb0/hsb8/etc)        | Desktop (pcg0)                 |
| ------------------ | ----------------------------- | ------------------------------ |
| **Base Modules**   | `commonServerModules`         | `commonDesktopModules`         |
| **Plasma Manager** | No                            | Yes (via commonDesktopModules) |
| **Espanso Fix**    | No                            | Yes (via commonDesktopModules) |
| **Gaming**         | No                            | Yes (`hokage.gaming.enable`)   |
| **Role**           | `server-home`/`server-remote` | Desktop (no explicit role)     |
| **Uzumaki Module** | `uzumaki/server.nix`          | `uzumaki/desktop.nix`          |

---

## ⚠️ Important Notes

1. **Omega User**: Keep the `omega` user definition unchanged - Patrizio can still log in
2. **Nixbit Repository**: Must point to `markus-barta/nixcfg` for system updates to work
3. **Desktop Modules**: `commonDesktopModules` includes plasma-manager and espanso-fix
4. **Gaming Features**: `hokage.gaming.enable = true` provides Steam, Gamescope, etc.
