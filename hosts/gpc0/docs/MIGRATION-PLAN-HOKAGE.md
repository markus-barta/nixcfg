# gpc0 → External Hokage Consumer Migration Plan

**Host**: gpc0 (Gaming PC 0, formerly mba-gaming-pc)  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🟢 **LOW** - Desktop system with GUI access  
**Status**: ✅ **CONFIG READY** - Awaiting deployment on host  
**Created**: November 29, 2025  
**Updated**: November 30, 2025

---

## 🎯 Migration Overview

### Current State (on host)

| Attribute      | Value                              |
| -------------- | ---------------------------------- |
| **Hostname**   | `mba-gaming-pc` (old!)             |
| **Git**        | `03572ef` (very behind)            |
| **Nix System** | mba-gaming-pc-25.11.20251117       |
| **Needs**      | `git pull && nixos-rebuild switch` |

### Target State (in repo)

| Attribute     | Value                                                    |
| ------------- | -------------------------------------------------------- |
| **Hostname**  | `gpc0`                                                   |
| **Structure** | External hokage from `github:pbek/nixcfg`                |
| **Pattern**   | Explicit module list with commonDesktopModules           |
| **Uzumaki**   | Local `../../modules/uzumaki/desktop.nix` (kept)         |
| **Nixbit**    | Override to `https://github.com/markus-barta/nixcfg.git` |

---

## 📋 Migration Checklist

### Pre-Migration ✅

- [x] Rename host from `mba-gaming-pc` to `gpc0`
- [x] Update `flake.nix` to use external hokage for gpc0
- [x] Update `configuration.nix` to remove local hokage import
- [x] Add `hokage.programs.nixbit.repository` override
- [x] Keep `omega` user definition as-is
- [x] Keep local Uzumaki desktop module
- [x] Run `nix flake check` ✅
- [x] Add catppuccin override (Tokyo Night theming)

### Global Changes (All Hosts) ✅

- [x] Add `nixbit.repository` override to hsb0
- [x] Add `nixbit.repository` override to hsb1
- [x] Add `nixbit.repository` override to hsb8
- [x] Add `nixbit.repository` override to csb0
- [x] Add `nixbit.repository` override to csb1

### Deployment (TODO)

- [ ] SSH to gpc0 or use local terminal
- [ ] `cd ~/Code/nixcfg && git pull`
- [ ] `sudo nixos-rebuild switch --flake .#gpc0`
- [ ] Verify hostname changed: `hostname` should show `gpc0`
- [ ] Reboot recommended (hostname change)

---

## 🔐 Security Notes

**gpc0 is LOW RISK because:**

1. ✅ **Physical access** - You have GUI/keyboard access
2. ✅ **Local network** - Not exposed to internet
3. ✅ **Gaming PC** - No critical services

**No special security measures needed** - unlike cloud servers where SSH is the only access.

**Omega user (`omega` account = Patrizio Bekerle):**

- Can SSH as `omega@192.168.1.154` when on local network
- No external access (not port-forwarded to internet)
- Keep as-is for when Patrizio visits/helps with the system

---

## 🚀 Deployment Commands

```bash
# Option 1: SSH from imac
ssh mba@192.168.1.154
cd ~/Code/nixcfg  # or wherever it is
git pull
sudo nixos-rebuild switch --flake .#gpc0

# Option 2: Local terminal on gpc0
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#gpc0

# After switch - verify
hostname  # Should show: gpc0
readlink /run/current-system | sed 's/.*-nixos-system-//'  # Should show: gpc0-...
```

---

## 🔑 Key Differences from Server Migration

| Aspect             | Server (hsb0/hsb8/etc)        | Desktop (gpc0)                 |
| ------------------ | ----------------------------- | ------------------------------ |
| **Base Modules**   | `commonServerModules`         | `commonDesktopModules`         |
| **Plasma Manager** | No                            | Yes (via commonDesktopModules) |
| **Espanso Fix**    | No                            | Yes (via commonDesktopModules) |
| **Gaming**         | No                            | Yes (`hokage.gaming.enable`)   |
| **Role**           | `server-home`/`server-remote` | Desktop (no explicit role)     |
| **Uzumaki Module** | `uzumaki/server.nix`          | `uzumaki/desktop.nix`          |
| **Risk Level**     | 🟡 Medium (SSH only)          | 🟢 Low (GUI access)            |

---

## ⚠️ Important Notes

1. **Omega User**: Keep the `omega` user definition unchanged - Patrizio can still log in (as `omega` user, not `mba`)
2. **Nixbit Repository**: Must point to `markus-barta/nixcfg` for system updates to work
3. **Desktop Modules**: `commonDesktopModules` includes plasma-manager and espanso-fix
4. **Gaming Features**: `hokage.gaming.enable = true` provides Steam, Gamescope, etc.
