# macOS Host Template

Copy this directory to create a new macOS host configuration.

## Quick Start

```bash
# 1. Copy template
cp -r hosts/_template-macos hosts/YOUR-HOSTNAME

# 2. Customize home.nix (see sections marked with ← CHANGE THIS)

# 3. Add theme palette to modules/uzumaki/theme/theme-palettes.nix:
#    "YOUR-HOSTNAME" = "warmGray";

# 4. Add to flake.nix homeConfigurations section

# 5. Apply on target Mac:
#    nix run home-manager -- switch --flake ".#USER@YOUR-HOSTNAME"
```

## Files to Customize

| File                                          | What to Change                                 |
| --------------------------------------------- | ---------------------------------------------- |
| `home.nix`                                    | hostname, username, Git identity, architecture |
| `../modules/uzumaki/theme/theme-palettes.nix` | Add host → palette mapping                     |
| `../flake.nix`                                | Register homeConfiguration                     |

## Architecture

**Important:** Check agenix package in home.nix:

- **Intel Mac** (`uname -m` = `x86_64`): Use `x86_64-darwin`
- **Apple Silicon** (`uname -m` = `arm64`): Use `aarch64-darwin`

## Full Guide

See **[docs/MACOS-SETUP.md](../../docs/MACOS-SETUP.md)** for complete step-by-step instructions.
