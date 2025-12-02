# Deployment Status

## Current Repository

| Attribute   | Value                                                               |
| ----------- | ------------------------------------------------------------------- |
| **Commit**  | `b8eed49e`                                                          |
| **Message** | fix: update starship template styles for user and hostname sections |

## NixOS Host Status

| Host | Commit     | System Build                | Git | Built | Action         | Checked          |
| ---- | ---------- | --------------------------- | --- | ----- | -------------- | ---------------- |
| hsb0 | `b8eed49e` | hsb0-26.05.20251127.2fad6ea | ✅  | ✅    | —              | 2025-12-02 17:55 |
| hsb1 | `c091b9c9` | hsb1-25.11.20251117.89c2b23 | 🟡  | 🟡    | `just upgrade` | 2025-11-30 09:38 |
| hsb8 | —          | —                           | ⚫  | ⚫    | —              | 2025-11-30 09:38 |
| csb0 | `af420880` | csb0-25.11.20251117.89c2b23 | 🟡  | ✅    | `git pull`     | 2025-11-30 09:38 |
| csb1 | `f71b56ca` | csb1-25.11.20251117.89c2b23 | 🟡  | ✅    | `git pull`     | 2025-11-30 09:38 |
| gpc0 | `03572ef`  | gpc0-25.11.20251117         | 🟡  | 🟡    | `just upgrade` | 2025-11-30 09:42 |

## macOS Home Manager Status

| Host          | Commit    | HM Generation | Git | Built | Action | Checked          |
| ------------- | --------- | ------------- | --- | ----- | ------ | ---------------- |
| imac-mba-work | `8b55088` | gen 16        | ✅  | ✅    | —      | 2025-12-01 13:11 |
| imac0         | —         | —             | ⚫  | ⚫    | —      | —                |

### Legend

| Icon | Meaning               |
| ---- | --------------------- |
| ✅   | Current / In sync     |
| 🟡   | Behind / Needs update |
| ⚫   | Offline / Unknown     |

- **Git**: Does host commit match repo HEAD (`b8eed49e`)?
- **Built**: Was system rebuilt from host's current commit?
- **Action**: Command to run — `git pull`, `just switch`, `just upgrade`, or —

## Quick Commands

```bash
# Home servers (port 22)
ssh mba@192.168.1.99   # hsb0 → cd ~/Code/nixcfg
ssh mba@192.168.1.101  # hsb1 → cd ~/Code/nixcfg
ssh mba@192.168.1.154  # gpc0 → cd ~/Code/nixcfg

# Cloud servers (port 2222)
ssh -p 2222 mba@cs0.barta.cm  # csb0 → cd ~/nixcfg
ssh -p 2222 mba@cs1.barta.cm  # csb1 → cd ~/nixcfg

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
