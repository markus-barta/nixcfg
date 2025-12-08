# Initial Setup Guide: mba-mbp-work

This guide walks you through setting up a fresh MacBook Pro with Nix, Home Manager, and the uzumaki configuration.

---

## Prerequisites

- Fresh macOS installation (or existing Mac you want to configure)
- Admin access
- Internet connection
- ~30-60 minutes

---

## Step 1: Rename Your Mac

macOS hostname must match the configuration name for proper theming.

### Via System Settings (GUI)

1. Open **System Settings** → **General** → **About**
2. Click on the computer name at the top
3. Change to: `mba-mbp-work`
4. Press Enter to confirm

### Via Terminal

```bash
# Set all hostname variants
sudo scutil --set ComputerName "mba-mbp-work"
sudo scutil --set HostName "mba-mbp-work"
sudo scutil --set LocalHostName "mba-mbp-work"

# Verify
scutil --get ComputerName    # → mba-mbp-work
scutil --get HostName        # → mba-mbp-work
scutil --get LocalHostName   # → mba-mbp-work
hostname                     # → mba-mbp-work
```

**Note**: You may need to restart for all changes to take effect.

---

## Step 2: Enable SSH (Remote Login)

Enable SSH so you can access this Mac remotely and deploy configurations.

### Via System Settings (GUI)

1. Open **System Settings** → **General** → **Sharing**
2. Find **Remote Login** and toggle it ON
3. Click the (i) info button
4. Set "Allow access for" to **Only these users** or **All users**
5. If "Only these users", click (+) and add your user

### Via Terminal

```bash
# Enable SSH daemon
sudo systemsetup -setremotelogin on

# Verify it's running
sudo systemsetup -getremotelogin
# → Remote Login: On

# Check SSH is listening
sudo lsof -i :22
# Should show sshd listening
```

### Test SSH Locally

```bash
ssh localhost
# Should prompt for password or use your SSH key
```

---

## Step 3: Install Nix Package Manager

We use the **official NixOS.org installer** in multi-user (daemon) mode.

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

### After Installation

```bash
# Open a NEW terminal window (or restart your terminal)

# Verify Nix is installed
nix --version
# → nix (Nix) 2.x.x
```

### Enable Flakes (Required)

The official installer does NOT enable flakes by default:

```bash
# Edit nix.conf
sudo nano /etc/nix/nix.conf

# Add these lines:
experimental-features = nix-command flakes
trusted-users = root mba

# Save and exit (Ctrl+O, Enter, Ctrl+X)

# Restart nix daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon

# Verify flakes work
nix flake --help
# Should show flake subcommands
```

**Note**: The official installer:

- Creates the /nix APFS volume
- Sets up build users (nixbld1-10)
- Configures the Nix daemon (launchd)

---

## Step 4: Clone the Configuration Repository

```bash
# Create Code directory if it doesn't exist
mkdir -p ~/Code

# Clone the repository
cd ~/Code
git clone https://github.com/markus-barta/nixcfg.git

# Enter the repository
cd nixcfg
```

---

## Step 5: Apply Home Manager Configuration

This installs Home Manager and applies your configuration in one command.

```bash
cd ~/Code/nixcfg

# First-time install: run home-manager via nix run
nix run home-manager -- switch --flake ".#mba@mba-mbp-work"
```

This will:

- Install home-manager
- Install all packages (fish, starship, wezterm, etc.)
- Configure your shell, terminal, and tools
- Set up theming (warm gray palette for this laptop)

**Note**: First run may take 5-15 minutes as it downloads packages.

---

## Step 6: Set Fish as Default Shell

```bash
# Add Nix fish to allowed shells
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells

# Set fish as your default login shell
chsh -s ~/.nix-profile/bin/fish

# Restart your terminal (or open a new one)
```

### Verify Fish is Working

```bash
# Check you're in fish
echo $SHELL
# → /Users/mba/.nix-profile/bin/fish

# Check fish version
fish --version

# Check starship prompt is showing
# (You should see the warm gray themed prompt)
```

---

## Step 7: Install Karabiner-Elements (Optional)

For keyboard remapping (Caps Lock → Hyper key):

```bash
# Install via Homebrew
brew install --cask karabiner-elements
```

### Grant Permissions

1. Open **System Settings** → **Privacy & Security** → **Input Monitoring**
2. Enable **karabiner_grabber** and **Karabiner-Elements**
3. You may need to restart Karabiner

The configuration is already linked via home-manager at `~/.config/karabiner/karabiner.json`.

---

## Step 8: Configure trusted-users (If Needed)

If you see "Failed to set up binary caches" warnings:

```bash
# Edit Nix configuration
sudo nano /etc/nix/nix.conf

# Add or modify this line:
trusted-users = root markus

# Save and restart nix-daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

**Note**: The Determinate Systems installer usually handles this automatically.

---

## Step 9: Verify Everything Works

### Quick Verification Script

```bash
# Check all tools come from Nix
which fish starship git node python3 bat btop
# All should show: /Users/mba/.nix-profile/bin/...

# Check fish functions work
pingt 8.8.8.8
# Should show timestamped pings with colors

# Check helpfish shows available functions
helpfish

# Check theme is applied (light gray prompt)
# Your prompt should have a cool silver/gray tint

# Check new uzumaki functions
hostcolors   # Show all hosts with colors
hostsecrets  # Show runbook secrets status
```

### Test Git Identity

```bash
# In work project (default identity)
cd ~/Code/some-work-project
git config user.email
# → markus.barta@bytepoets.com

# In nixcfg (personal identity)
cd ~/Code/nixcfg
git config user.email
# → markus@barta.com
```

---

## Step 10: Enable direnv + devenv (For Development)

The nixcfg repo uses direnv + devenv for its development environment:

```bash
cd ~/Code/nixcfg

# Allow direnv to run .envrc
direnv allow

# Wait for devenv to download dependencies (first time is slow)
# You should see: "🛠️ nixcfg  macOS"

# Verify just works
just --list
```

**If `just` fails with "Could not find source file for import":**

This means the direnv → devenv → .shared/common.just chain broke:

1. Check `devenv` is installed: `which devenv`
2. If missing: already fixed, just run `home-manager switch`
3. Re-allow direnv: `direnv allow`

See `docs/MACOS-SETUP.md` section 5.3 for the full chain explanation.

---

## Daily Usage

### Apply Configuration Changes

```bash
cd ~/Code/nixcfg

# Pull latest changes
git pull

# Apply configuration
just switch
# or: home-manager switch --flake ".#mba@mba-mbp-work"
```

### Update All Packages

```bash
cd ~/Code/nixcfg

# Update flake.lock to latest versions
just update

# Apply updates
just switch
```

---

## Troubleshooting

### "command not found" After Switch

Restart your terminal or run:

```bash
exec fish
```

### PATH Not Prioritizing Nix

Check PATH order:

```bash
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

If not, the fish `loginShellInit` should fix this on new terminal windows.

### WezTerm Not Found in Spotlight

WezTerm should appear in Spotlight automatically. The activation script creates
a **macOS alias** (not symlink) in `~/Applications/` because symlinks to
`/nix/store` don't get indexed by Spotlight.

If WezTerm doesn't appear:

1. Run `home-manager switch` to create the alias
2. Wait a moment for Spotlight to index
3. Check: `mdfind "WezTerm*"` should show `~/Applications/WezTerm.app`

**Technical note**: Check that `~/Applications/WezTerm.app` is a **file**
(~1KB), not a symlink. If it's a symlink, the activation script needs updating.

### Nix Store Location

Nix uses a dedicated APFS volume at `/nix`. This is normal and doesn't affect your main disk.

---

## Architecture Notes

### Apple Silicon (M1/M2/M3)

If your MacBook has Apple Silicon:

1. The configuration should work as-is
2. Some packages may need Rosetta 2 for x86_64 binaries
3. Install Rosetta if prompted: `softwareupdate --install-rosetta`

### Intel Mac

The configuration is set for `x86_64-darwin`. No changes needed.

---

## What's Included

After setup, you'll have:

| Tool       | Purpose                            |
| ---------- | ---------------------------------- |
| Fish       | Modern shell                       |
| Starship   | Beautiful prompt (warm gray)       |
| WezTerm    | GPU-accelerated terminal           |
| Git        | With dual identity (work/personal) |
| bat        | Better cat                         |
| ripgrep    | Fast grep (rg)                     |
| fd         | Fast find                          |
| fzf        | Fuzzy finder                       |
| btop       | System monitor                     |
| zoxide     | Smart cd (z)                       |
| just       | Command runner                     |
| lazygit    | Git TUI                            |
| nodejs     | Node.js runtime                    |
| python3    | Python 3 runtime                   |
| pingt      | Timestamped ping                   |
| sourcefish | Load .env files                    |
| helpfish   | Show available functions           |

---

## Next Steps

1. ✅ Verify all tools work
2. ⏳ Copy SSH keys from old machine (if migrating)
3. ⏳ Set up Git SSH keys for GitHub
4. ⏳ Install additional Homebrew casks (GUI apps)
5. ⏳ Configure 1Password SSH agent (optional)

---

**Created**: December 5, 2025  
**Last Updated**: December 5, 2025
