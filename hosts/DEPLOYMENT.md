# 🌀 Deployment Status

## Current Repository

| Attribute   | Value                                                  |
| ----------- | ------------------------------------------------------ |
| **Commit**  | `4f0ebf36`                                             |
| **Message** | docs: 🌀 only for hosts with uzumaki actually deployed |

## NixOS Host Status

| Host | Status | Commit     | System Build                | Action        | Checked          |
| ---- | ------ | ---------- | --------------------------- | ------------- | ---------------- |
| hsb1 | 🌀✨   | `117dd53e` | hsb1-26.05.20251130.2d293cb | —             | 2025-12-04 19:15 |
| hsb0 | 🌀✨   | `4f0ebf36` | hsb0-26.05.20251127.2fad6ea | —             | 2025-12-04 19:20 |
| gpc0 | 🔄     | `e3298aa5` | gpc0-26.05.20251127.2fad6ea | `just switch` | 2025-12-04 19:07 |
| hsb8 | 🟡     | —          | —                           | migrate       | 2025-12-04 19:07 |
| csb0 | ⏸️     | `af420880` | csb0-25.11.20251117.89c2b23 | Phase II      | 2025-12-04 19:07 |
| csb1 | ⏸️     | `f71b56ca` | csb1-25.11.20251117.89c2b23 | Phase II      | 2025-12-04 19:07 |

## macOS Home Manager Status

| Host          | Status | Commit     | HM Generation | Action        | Checked          |
| ------------- | ------ | ---------- | ------------- | ------------- | ---------------- |
| imac0         | 🔄     | `e3298aa5` | gen 69        | `just switch` | 2025-12-04 19:07 |
| imac-mba-work | ⚫     | —          | —             | —             | 2025-12-04 19:07 |

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

| Host          | Platform | Role        | 🌀 Import                          |
| ------------- | -------- | ----------- | ---------------------------------- |
| hsb1          | NixOS    | server      | `modules/uzumaki`                  |
| hsb0          | NixOS    | server      | `modules/uzumaki`                  |
| gpc0          | NixOS    | desktop     | `modules/uzumaki`                  |
| imac0         | macOS    | workstation | `modules/uzumaki/home-manager.nix` |
| imac-mba-work | macOS    | workstation | `modules/uzumaki/home-manager.nix` |

### 🟡 Needs Migration (Phase I Pending)

| Host | Platform | Current Import       | Status  |
| ---- | -------- | -------------------- | ------- |
| hsb8 | NixOS    | `uzumaki/server.nix` | Offline |

### ⏸️ Deferred to Phase II (Cloud Servers)

| Host | Platform | Current Import       | Notes                               |
| ---- | -------- | -------------------- | ----------------------------------- |
| csb0 | NixOS    | `uzumaki/server.nix` | Uses old mixins, needs hokage first |
| csb1 | NixOS    | `uzumaki/server.nix` | Uses old mixins, needs hokage first |

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

```
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
