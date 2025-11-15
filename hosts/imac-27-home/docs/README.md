# Documentation Structure

## Overview

This directory contains all documentation for the `imac-27-home` host configuration.

```
docs/
├── README.md                    # This file
├── progress.md                  # Migration history & current state
├── manual-setup/                # One-time manual setup guides
│   ├── karabiner-setup.md       # Karabiner-Elements install & config
│   └── terminal-app-fonts.md    # Terminal.app font setup
└── reference/                   # Technical documentation
    ├── karabiner-elements.md    # Karabiner technical details
    ├── macos-gui-apps.md        # GUI app management solution
    └── hardware-info.md         # System specifications
```

## Quick Links

- **🚀 [Current Status & Progress](progress.md)** - See where the migration stands
- **🛠️ [Manual Setup Guides](manual-setup/)** - One-time configuration steps
- **📚 [Technical Reference](reference/)** - Deep dives into specific features

## For New Machines

When setting up a new machine (`imac-27-work`, etc.):

1. Read [progress.md](progress.md) → "Future Machines" section
2. Follow [manual-setup/](manual-setup/) guides for non-declarative steps
3. Reference [reference/](reference/) docs for technical understanding

## File Structure Context

The full host directory structure:

```
hosts/imac-27-home/
├── config/                      # Configuration files
│   ├── starship.toml
│   └── karabiner.json
├── docs/                        # This documentation
│   ├── README.md                # (you are here)
│   ├── progress.md
│   ├── manual-setup/
│   └── reference/
├── scripts/
│   ├── setup/                   # Setup & migration scripts
│   │   ├── backup-migration.sh
│   │   └── setup-macos.sh
│   └── host-user/               # Daily user utilities
│       ├── flushdns.sh
│       ├── pingt.sh
│       └── stopAmphetamineAndSleep.sh
└── home.nix                     # Main configuration
```

---

**Note**: This structure was designed for clarity and maintainability. Essential scripts are in git, comprehensive history in progress.md, and manual steps clearly documented.
