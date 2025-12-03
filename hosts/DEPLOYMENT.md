# Deployment Status

## Current Repository

| Attribute   | Value                                                    |
| ----------- | -------------------------------------------------------- |
| **Commit**  | `a06e1181`                                               |
| **Message** | docs: complete StaSysMo MVP, add dev notes, move to done |

## NixOS Host Status

| Host | Commit     | System Build                | Git | Built | Action         | Checked          |
| ---- | ---------- | --------------------------- | --- | ----- | -------------- | ---------------- |
| hsb0 | `a06e1181` | hsb0-26.05.20251127.2fad6ea | ✅  | ✅    | —              | 2025-12-03 19:55 |
| hsb1 | `c091b9c9` | hsb1-25.11.20251117.89c2b23 | 🟡  | 🟡    | `just upgrade` | 2025-12-03 19:55 |
| hsb8 | —          | —                           | ⚫  | ⚫    | —              | 2025-12-03 19:55 |
| csb0 | `af420880` | csb0-25.11.20251117.89c2b23 | 🟡  | 🟡    | `just upgrade` | 2025-12-03 19:55 |
| csb1 | `f71b56ca` | csb1-25.11.20251117.89c2b23 | 🟡  | 🟡    | `just upgrade` | 2025-12-03 19:55 |
| gpc0 | —          | —                           | ⚫  | ⚫    | —              | 2025-12-03 19:55 |

## macOS Home Manager Status

| Host          | Commit     | HM Generation | Git | Built | Action         | Checked          |
| ------------- | ---------- | ------------- | --- | ----- | -------------- | ---------------- |
| imac0         | `a06e1181` | gen 68        | ✅  | ✅    | —              | 2025-12-03 19:55 |
| imac-mba-work | `8b55088`  | gen 16        | 🟡  | 🟡    | `just upgrade` | 2025-12-01 13:11 |

### Legend

| Icon | Meaning               |
| ---- | --------------------- |
| ✅   | Current / In sync     |
| 🟡   | Behind / Needs update |
| ⚫   | Offline / Unknown     |

- **Git**: Does host commit match repo HEAD (`a06e1181`)?
- **Built**: Was system rebuilt from host's current commit?
- **Action**: Command to run — `git pull`, `just switch`, `just upgrade`, or —

## Quick Commands

```bash
# Home servers (port 22)
ssh mba@192.168.1.99   # hsb0 → cd ~/Code/nixcfg
ssh mba@192.168.1.101  # hsb1 → cd ~/Code/nixcfg
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
