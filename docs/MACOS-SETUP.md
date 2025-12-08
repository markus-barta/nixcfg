# macOS Setup Guide

Step-by-step guide for setting up a new Mac with Nix, Home Manager, and Uzumaki.

**Use cases:**

- New work machines (BYTEPOETS)
- Family machines
- Personal machines

**Time required:** ~30-60 minutes

---

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  1. Prepare Mac          → Set hostname, enable SSH            │
│  2. Install Nix          → Determinate Systems installer       │
│  3. Create Host Config   → Copy template, customize            │
│  4. Apply Configuration  → home-manager switch                 │
│  5. Post-Install Setup   → Fish shell, verify                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Prepare the Mac

### 1.1 Set Hostname

The hostname must match the configuration name for proper theming.

**Via Terminal (recommended):**

```bash
# Set all hostname variants (replace NEW-HOSTNAME with your choice)
sudo scutil --set ComputerName "NEW-HOSTNAME"
sudo scutil --set HostName "NEW-HOSTNAME"
sudo scutil --set LocalHostName "NEW-HOSTNAME"

# Verify
scutil --get ComputerName
scutil --get HostName
scutil --get LocalHostName
hostname
```

**Via GUI:**

1. Open **System Settings** → **General** → **About**
2. Click the computer name at the top
3. Change to your chosen hostname
4. Press Enter

### 1.2 Naming Conventions

| Pattern             | Example                         | Use Case          |
| ------------------- | ------------------------------- | ----------------- |
| `mba-{device}-work` | `mba-mbp-work`, `mba-imac-work` | Work machines     |
| `{device}{n}`       | `imac0`, `mbp1`                 | Personal machines |
| `{family}-{device}` | `mom-imac`, `dad-mbp`           | Family machines   |

### 1.3 Enable SSH (Optional but Recommended)

Enables remote deployment and troubleshooting.

**Via Terminal:**

```bash
# Enable SSH daemon
sudo systemsetup -setremotelogin on

# Verify
sudo systemsetup -getremotelogin
# → Remote Login: On
```

**Via GUI:**

1. **System Settings** → **General** → **Sharing**
2. Toggle **Remote Login** ON
3. Set access permissions

### 1.4 Gather System Information

Run this on the target Mac:

```bash
echo "=== System Information ==="
echo "Hostname: $(hostname)"
echo "Architecture: $(uname -m)"  # x86_64 = Intel, arm64 = Apple Silicon
echo "macOS: $(sw_vers -productVersion)"
echo "User: $(whoami)"
echo "Home: $HOME"
```

**Save these values - you'll need them for configuration.**

---

## Phase 2: Install Nix

We use the **official NixOS.org installer** in multi-user (daemon) mode.

### 2.1 Run Installer

**Important:** This command uses process substitution which does NOT work in fish shell.
You must run it in bash/zsh:

```bash
# Switch to bash first (required if using fish!)
bash

# Install Nix (official multi-user installation)
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install)

# Follow the prompts
```

See: [nix.dev/install-nix](https://nix.dev/install-nix)

### 2.2 Verify Installation

**Open a NEW terminal window**, then:

```bash
# Check Nix version
nix --version
# → nix (Nix) 2.x.x
```

### 2.3 Enable Flakes (Required)

The official installer does NOT enable flakes by default. Add to `/etc/nix/nix.conf`:

```bash
# Edit nix.conf (requires sudo)
sudo nano /etc/nix/nix.conf

# Add these lines:
experimental-features = nix-command flakes
trusted-users = root YOUR-USERNAME
```

Then restart the Nix daemon:

```bash
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

Verify flakes work:

```bash
nix flake --help
# Should show flake subcommands
```

**The official installer:**

- Creates the /nix APFS volume
- Sets up build users (nixbld1-10)
- Configures the Nix daemon (launchd)

---

## Phase 3: Create Host Configuration

### 3.1 Clone Repository

```bash
# Create Code directory
mkdir -p ~/Code

# Clone the repository
cd ~/Code
git clone https://github.com/YOUR-USERNAME/nixcfg.git

# Enter repository
cd nixcfg
```

### 3.2 Create Host Directory

```bash
# Create host directory structure
HOSTNAME="your-hostname"  # e.g., mba-mbp-work
mkdir -p hosts/$HOSTNAME/{docs,scripts/host-user,secrets,tests}
```

### 3.3 Copy Template Files

Use imac0 or mba-mbp-work as a template:

```bash
# Copy home.nix template
cp hosts/imac0/home.nix hosts/$HOSTNAME/home.nix

# Copy test README
cp hosts/imac0/tests/README.md hosts/$HOSTNAME/tests/README.md
```

### 3.4 Customize home.nix

Edit `hosts/$HOSTNAME/home.nix`:

```nix
{
  pkgs,
  lib,
  inputs,
  ...
}:

{
  # ============================================================================
  # Module Imports
  # ============================================================================
  imports = [
    ../../modules/uzumaki/home-manager.nix
  ];

  # ============================================================================
  # UZUMAKI MODULE
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "workstation";
    fish.editor = "nano";  # or "vim", "code", etc.
    stasysmo.enable = true;
  };

  # Theme configuration - MUST match actual hostname
  theme.hostname = "YOUR-HOSTNAME";  # ← CHANGE THIS

  # User settings
  home.username = "YOUR-USERNAME";   # ← CHANGE THIS (usually "markus")
  home.homeDirectory = "/Users/YOUR-USERNAME";  # ← CHANGE THIS

  home.stateVersion = "24.11";
  home.enableNixpkgsReleaseCheck = false;
  programs.home-manager.enable = true;

  # ... rest of configuration (copy from imac0/home.nix)
}
```

### 3.5 Fix Architecture (Apple Silicon vs Intel)

**Critical:** Check the agenix package architecture in home.nix:

```nix
home.packages = with pkgs; [
  # For Intel Mac (x86_64)
  inputs.agenix.packages.x86_64-darwin.default

  # For Apple Silicon (M1/M2/M3) - use this instead:
  # inputs.agenix.packages.aarch64-darwin.default

  # ... rest of packages
];
```

**Tip:** Use `uname -m` on the target Mac:

- `x86_64` → Intel → `x86_64-darwin`
- `arm64` → Apple Silicon → `aarch64-darwin`

### 3.6 Add Theme Palette

Edit `modules/uzumaki/theme/theme-palettes.nix`:

```nix
{
  # Add your new host
  "your-hostname" = "warmGray";  # or lightGray, darkGray, etc.

  # Existing hosts...
  "imac0" = "warmGray";
  "mba-mbp-work" = "lightGray";
}
```

**Available palettes:** `lightGray`, `darkGray`, `warmGray`, `coolGray`, `tealAccent`, `purpleAccent`

### 3.7 Register in flake.nix

Add to `flake.nix` in the `homeConfigurations` section:

```nix
homeConfigurations = {
  # Existing hosts...
  "markus@imac0" = home-manager.lib.homeManagerConfiguration { ... };

  # Add new host
  "YOUR-USERNAME@YOUR-HOSTNAME" = home-manager.lib.homeManagerConfiguration {
    pkgs = import nixpkgs {
      system = "x86_64-darwin";  # or "aarch64-darwin" for Apple Silicon
      config.allowUnfree = true;
    };
    extraSpecialArgs = commonArgs;
    modules = [ ./hosts/YOUR-HOSTNAME/home.nix ];
  };
};
```

### 3.8 Configure Git Identity

Edit the Git section in your home.nix:

**For personal machines:**

```nix
programs.git = {
  enable = true;
  settings.user = {
    name = "Your Name";
    email = "your@email.com";
  };
};
```

**For work machines (BYTEPOETS style):**

```nix
programs.git = {
  enable = true;
  settings.user = {
    name = "mba";  # Work identity default
    email = "markus.barta@bytepoets.com";
  };

  # Personal identity for personal projects
  includes = [
    {
      condition = "gitdir:~/Code/personal/";
      contents.user = {
        name = "Markus Barta";
        email = "markus@barta.com";
      };
    }
    {
      condition = "gitdir:~/Code/nixcfg/";
      contents.user = {
        name = "Markus Barta";
        email = "markus@barta.com";
      };
    }
  ];
};
```

---

## Phase 4: Apply Configuration

### 4.1 First-Time Installation

```bash
cd ~/Code/nixcfg

# Run home-manager via nix run (first time only)
nix run home-manager -- switch --flake ".#YOUR-USERNAME@YOUR-HOSTNAME"
```

**This will:**

- Install home-manager
- Install all packages (fish, starship, wezterm, etc.)
- Configure shell, terminal, and tools
- Set up theming

**Note:** First run takes 5-15 minutes.

### 4.2 Subsequent Updates

After first install, use:

```bash
# Via just (recommended)
just switch

# Or directly
home-manager switch --flake ".#YOUR-USERNAME@YOUR-HOSTNAME"
```

---

## Phase 5: Post-Install Setup

### 5.1 Set Fish as Default Shell

```bash
# Add Nix fish to allowed shells
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells

# Set fish as default login shell
chsh -s ~/.nix-profile/bin/fish

# Restart terminal or:
exec fish
```

### 5.2 Verify Installation

```bash
# Check tools come from Nix
which fish starship git node python3 bat btop
# All should show: /Users/XXX/.nix-profile/bin/...

# Check fish functions
pingt -c 1 127.0.0.1
# Should show timestamped pings with colors

# Check helpfish
helpfish
# Should display functions, aliases, abbreviations

# Check theme (starship prompt should have correct colors)
```

### 5.3 Enable direnv + devenv (Required for nixcfg)

The nixcfg repo uses **direnv** + **devenv** for development environment setup:

```
┌─────────────────────────────────────────────────────────────────┐
│  THE CHAIN: How .shared/common.just gets created                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. You enter ~/Code/nixcfg                                     │
│           │                                                     │
│           ▼                                                     │
│  2. direnv detects .envrc                                       │
│           │                                                     │
│           ▼                                                     │
│  3. .envrc runs: eval "$(devenv direnvrc)" && use devenv        │
│           │                                                     │
│           ▼                                                     │
│  4. devenv reads devenv.yaml                                    │
│           │                                                     │
│           ▼                                                     │
│  5. devenv.yaml imports: shared/common (from github:pbek/...)   │
│           │                                                     │
│           ▼                                                     │
│  6. Creates .shared/common.just symlink → Nix store             │
│           │                                                     │
│           ▼                                                     │
│  7. justfile can now: import ".shared/common.just"              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**First time setup:**

```bash
cd ~/Code/nixcfg
direnv allow

# Wait for devenv to download dependencies (first time is slow)
# You'll see: "🛠️ nixcfg  macOS" when ready

# Verify
just --list
```

**If `just` fails with "Could not find source file for import":**

- `devenv` is not installed → run `home-manager switch` to get it
- `direnv allow` wasn't run → run `direnv allow`
- First time → wait for devenv to create `.shared/`

### 5.4 Install Karabiner-Elements (Optional)

For keyboard remapping (Caps Lock → Hyper key):

```bash
brew install --cask karabiner-elements
```

Then grant permissions:

1. **System Settings** → **Privacy & Security** → **Input Monitoring**
2. Enable **karabiner_grabber** and **Karabiner-Elements**

Configuration is already linked via home-manager.

---

## Phase 6: Create Documentation

### 6.1 Create README.md

Create `hosts/YOUR-HOSTNAME/README.md`:

```markdown
# YOUR-HOSTNAME - Description

Brief description of this machine.

## Quick Reference

| Item               | Value                    |
| ------------------ | ------------------------ |
| **Hostname**       | `YOUR-HOSTNAME`          |
| **Model**          | MacBook Pro / iMac / etc |
| **OS**             | macOS XX.X               |
| **Architecture**   | Apple Silicon / Intel    |
| **User**           | `username`               |
| **Shell**          | Fish (via Nix)           |
| **Config Manager** | home-manager             |
| **Apply Config**   | `just switch`            |
| **Theme**          | warmGray / lightGray     |

## Features

| ID  | Feature           | Description                 |
| --- | ----------------- | --------------------------- |
| F00 | Nix Base System   | Reproducible package mgmt   |
| F01 | Fish Shell        | Modern shell with functions |
| F02 | Starship Prompt   | Beautiful themed prompt     |
| F03 | WezTerm Terminal  | GPU-accelerated terminal    |
| F04 | Git Identity      | Personal/work auto-switch   |
| F05 | CLI Tools         | bat, ripgrep, fd, fzf, etc. |
| F06 | Uzumaki Functions | pingt, helpfish, sourcefish |
```

### 6.2 Create RUNBOOK.md

Create `hosts/YOUR-HOSTNAME/docs/RUNBOOK.md` with common procedures.

---

## Troubleshooting

### "command not found" After Switch

```bash
# Restart shell
exec fish

# Or check PATH
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

### Architecture Mismatch Error

If you see errors about `x86_64-darwin` vs `aarch64-darwin`:

1. Check your Mac's architecture: `uname -m`
2. Update home.nix agenix package path
3. Update flake.nix system setting
4. Re-run `home-manager switch`

### Nix Daemon Not Running

```bash
# Check status
launchctl print system/org.nixos.nix-daemon

# Restart if needed
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

### WezTerm Not in Spotlight

WezTerm is linked to `~/Applications/`. Search in Spotlight (⌘+Space) or add to Dock manually.

---

## Quick Reference Commands

```bash
# Apply configuration
just switch
home-manager switch --flake ".#user@hostname"

# Update all packages
just update
nix flake update

# Check what would change
home-manager switch --flake ".#user@hostname" --dry-run

# Garbage collect old generations
nix-store --gc

# List generations
home-manager generations
```

---

## Checklist for New Mac

- [ ] **Phase 1: Prepare**
  - [ ] Set hostname (scutil or System Settings)
  - [ ] Enable SSH (optional)
  - [ ] Note architecture (Intel/Apple Silicon)

- [ ] **Phase 2: Install Nix**
  - [ ] Run Determinate installer
  - [ ] Verify `nix --version` in new terminal

- [ ] **Phase 3: Create Config**
  - [ ] Clone nixcfg repository
  - [ ] Create host directory
  - [ ] Copy and customize home.nix
  - [ ] Fix architecture in packages
  - [ ] Add theme palette entry
  - [ ] Register in flake.nix

- [ ] **Phase 4: Apply**
  - [ ] Run `nix run home-manager -- switch --flake ...`
  - [ ] Wait for packages to install

- [ ] **Phase 5: Post-Install**
  - [ ] Set fish as default shell
  - [ ] Verify all tools from Nix
  - [ ] Test pingt and helpfish
  - [ ] Install Karabiner (optional)

- [ ] **Phase 6: Documentation**
  - [ ] Create README.md
  - [ ] Create RUNBOOK.md
  - [ ] Commit to Git

---

## Related Documentation

- [HOST-TEMPLATE.md](./HOST-TEMPLATE.md) - NixOS host structure
- [AGENT-WORKFLOW.md](./AGENT-WORKFLOW.md) - Keeping config/docs/tests in sync
- [Uzumaki Module](../modules/uzumaki/README.md) - Fish functions and theming

---

**Last Updated:** December 2025  
**Maintainer:** Markus Barta
