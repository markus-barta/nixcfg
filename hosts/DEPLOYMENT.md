# 🌀 Deployment Status [DEPRECATED]

Note: This document is deprecated as of 2026-01-01. Nixfleet (fleet.barta.cm) is used for status for tracking.

## Current Repository

| Attribute   | Value                                                    |
| ----------- | -------------------------------------------------------- |
| **Commit**  | `5f539fb1`                                               |
| **Message** | fix(csb0): correct gateway and subnet from DHCP analysis |

## NixOS Host Status

| Host | Status | Commit     | System Build                | Action  | Checked          |
| ---- | ------ | ---------- | --------------------------- | ------- | ---------------- |
| hsb1 | 🔄     | `57a2b0cc` | hsb1-26.05.20251130.2d293cb | rebuild | 2025-12-06 13:54 |
| hsb0 | 🔄     | `57a2b0cc` | hsb0-26.05.20251127.2fad6ea | rebuild | 2025-12-06 13:54 |
| gpc0 | ⚫     | —          | —                           | —       | 2025-12-06 13:54 |
| hsb8 | ⚫     | —          | —                           | migrate | 2025-12-06 13:54 |
| csb0 | 🔄     | `5f539fb1` | csb0-26.05.20251127.2fad6ea | rebuild | 2025-12-06 13:54 |
| csb1 | 🔄     | `838951c6` | csb1-26.05.20251127.2fad6ea | rebuild | 2025-12-06 13:54 |

## macOS Home Manager Status

| Host  | Status | Commit     | HM Generation | Action | Checked          |
| ----- | ------ | ---------- | ------------- | ------ | ---------------- |
| imac0 | 🌀✨   | `5f539fb1` | gen 75        | —      | 2025-12-06 13:54 |

### Status Legend

| Status | Name              | Meaning                                                         |
| ------ | ----------------- | --------------------------------------------------------------- |
| 🌀✨   | **Perfect**       | 🌀 Uzumaki deployed + Git ✅ + Built ✅ (all done with honors!) |
| 🔄     | **Needs Rebuild** | Config ready in git, needs `just switch` to earn 🌀             |
| 🟡     | **Old Pattern**   | Uses old `uzumaki/server.nix`, needs migration first            |
| ⏸️     | **Deferred**      | Phase II (cloud servers - mixins → hokage first)                |
| ⚫     | **Offline**       | Can't reach host                                                |

## 🌀 Uzumaki Module Status

### ✅ Migrated to New Pattern (Phase I)

| Host  | Platform | Role        | 🌀 Import                          |
| ----- | -------- | ----------- | ---------------------------------- |
| hsb1  | NixOS    | server      | `modules/uzumaki`                  |
| hsb0  | NixOS    | server      | `modules/uzumaki`                  |
| gpc0  | NixOS    | desktop     | `modules/uzumaki`                  |
| imac0 | macOS    | workstation | `modules/uzumaki/home-manager.nix` |

### ⏳ Awaiting Deployment (Host Offline)

| Host | Platform | Config Status        | Notes                              |
| ---- | -------- | -------------------- | ---------------------------------- |
| hsb8 | NixOS    | ✅ `modules/uzumaki` | Config ready, host offline at WW87 |

### ✅ Phase II Complete (Cloud Servers with Hokage)

| Host | Platform | Current Import              | Notes                           |
| ---- | -------- | --------------------------- | ------------------------------- |
| csb0 | NixOS    | `github:pbek/nixcfg#hokage` | External hokage module deployed |
| csb1 | NixOS    | `github:pbek/nixcfg#hokage` | External hokage module deployed |

## Quick Commands

```bash
# Home servers (port 22)
ssh mba@192.168.1.99   # hsb0 → cd ~/Code/nixcfg
ssh mba@192.168.1.101  # hsb1 → cd ~/Code/nixcfg
ssh mba@192.168.1.100  # hsb8 → cd ~/Code/nixcfg
ssh mba@192.168.1.154  # gpc0 → cd ~/Code/nixcfg

# Cloud servers (port 2222)
ssh -p 2222 mba@cs0.barta.cm  # csb0 → cd ~/nixcfg (TODO: migrate to ~/Code/nixcfg)
ssh -p 2222 mba@cs1.barta.cm  # csb1 → cd ~/nixcfg (TODO: migrate to ~/Code/nixcfg)

# Check NixOS status
git log -1 --format='%h %s'
readlink /run/current-system | sed 's/.*-nixos-system-//'

# Check macOS Home Manager status
git log -1 --format='%h %s'
home-manager generations | head -1

# Update & deploy (NixOS)
git pull && sudo nixos-rebuild switch --flake .#<hostname>

# Update & deploy (macOS Home Manager)
git pull && home-manager switch --flake .#<hostname>
```

## 🌀 Architecture Overview

```text
modules/uzumaki/                    # Single source of truth
├── default.nix                     # NixOS entry point
├── home-manager.nix                # macOS/Home Manager entry point
├── options.nix                     # Shared options
├── fish/                           # Fish functions (pingt, stress, helpfish...)
├── stasysmo/                       # System monitoring
│   ├── nixos.nix                   # NixOS systemd service
│   └── home-manager.nix            # macOS launchd service
└── theme/                          # Per-host theming
    ├── theme-hm.nix                # Starship, Zellij, Eza config
    └── theme-palettes.nix          # Color definitions
```
