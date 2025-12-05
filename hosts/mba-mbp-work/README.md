# mba-mbp-work - Work MacBook Pro (BYTEPOETS)

Work macOS laptop with Nix package management.

## Quick Links

- 🚀 **[Initial Setup](docs/INITIAL-SETUP.md)** - First-time setup guide (rename host, enable SSH, install Nix)
- 🧪 **[Test Suite](tests/README.md)** - Validation tests for this configuration
- 📚 **[imac-mba-work README](../imac-mba-work/README.md)** - Work iMac (similar configuration)

---

## Quick Reference

| Item               | Value                                            |
| ------------------ | ------------------------------------------------ |
| **Hostname**       | `mba-mbp-work`                                   |
| **Model**          | MacBook Pro                                      |
| **OS**             | macOS (latest)                                   |
| **Architecture**   | Apple Silicon (aarch64) or Intel (x86_64)        |
| **User**           | `markus`                                         |
| **Shell**          | Fish (via Nix)                                   |
| **Terminal**       | WezTerm (via Nix)                                |
| **Config Manager** | home-manager (standalone)                        |
| **Git Default**    | Work identity (mba / markus.barta@bytepoets.com) |
| **Apply Config**   | `just switch` or `home-manager switch --flake .` |
| **Theme**          | Warm Gray (mobile workstation palette)           |

---

## Features

| ID  | Technical             | User-Friendly                                    |
| --- | --------------------- | ------------------------------------------------ |
| F00 | Nix Base System       | Reproducible package management with Flakes      |
| F01 | Fish Shell            | Modern shell with custom functions & aliases     |
| F02 | Git Dual Identity     | Auto-switch between work/personal Git identities |
| F03 | Starship Prompt       | Beautiful, informative prompt with Git status    |
| F04 | WezTerm Terminal      | GPU-accelerated terminal with custom config      |
| F05 | CLI Development Tools | bat, ripgrep, fd, fzf, btop, zoxide, jq, just    |
| F06 | direnv + devenv       | Automatic project environment loading            |
| F07 | Uzumaki Functions     | pingt, sourcefish, sourceenv, helpfish           |

---

## Directory Structure

```
hosts/mba-mbp-work/
├── config/                      # Configuration files (karabiner, etc.)
├── docs/                        # Documentation
│   └── INITIAL-SETUP.md         # First-time setup guide
├── scripts/
│   └── host-user/               # Daily user utilities
├── secrets/                     # Gitignored secrets
├── tests/                       # Test suite
├── home.nix                     # Main home-manager configuration
└── README.md                    # This file
```

---

## Making Changes

### Update Configuration

```bash
cd ~/Code/nixcfg

# Edit configuration
vim hosts/mba-mbp-work/home.nix

# Apply changes
just switch

# Or directly:
home-manager switch --flake ".#markus@mba-mbp-work"

# Commit to git
git add hosts/mba-mbp-work/
git commit -m "Update mba-mbp-work configuration"
git push
```

---

## Git Identity

- **Default (Work)**: mba / markus.barta@bytepoets.com
- **Personal** (~/Code/personal/, ~/Code/nixcfg/): Markus Barta / markus@barta.com

---

## Related Documentation

- [imac-mba-work README](../imac-mba-work/README.md) - Work iMac (similar config)
- [imac0 README](../imac0/README.md) - Home iMac
- [Main Repository README](../../README.md) - Repository overview

---

**Created**: December 5, 2025  
**Maintainer**: Markus Barta
