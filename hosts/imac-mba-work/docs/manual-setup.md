# Manual Setup Guide - imac-mba-work

One-time configuration steps that cannot be automated via home-manager.

## Overview

Home-manager on macOS is user-level only - it cannot modify system files or require elevated privileges. These steps must be done manually once per machine.

---

## 1. Nix Installation

### Option A: Determinate Systems Installer (Recommended)

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

**Benefits:**

- Automatically configures `trusted-users`
- Sets up flakes by default
- Better uninstall support

### Option B: Official Nix Installer

```bash
sh <(curl -L https://nixos.org/nix/install)
```

Then enable flakes:

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

---

## 2. Set Fish as Default Shell

```bash
# Add Nix fish to allowed shells
echo ~/.nix-profile/bin/fish | sudo tee -a /etc/shells

# Set as default login shell
chsh -s ~/.nix-profile/bin/fish

# Restart terminal
```

---

## 3. Configure trusted-users (if needed)

If you see "Failed to set up binary caches" warnings when using devenv:

```bash
# Edit Nix configuration
sudo nano /etc/nix/nix.conf

# Add this line:
trusted-users = root markus

# Restart nix-daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

---

## 4. Install Karabiner-Elements

Karabiner requires system-level drivers that must be installed via Homebrew:

```bash
brew install --cask karabiner-elements
```

After installation:

1. Open Karabiner-Elements from Applications
2. Grant "Input Monitoring" permission when prompted
3. System Preferences → Security & Privacy → Privacy → Input Monitoring
4. Enable both "karabiner_grabber" and "Karabiner-Elements"

The configuration is already linked via home-manager - just install the app!

---

## 5. Install devenv

devenv is used for the nixcfg development environment:

```bash
nix profile install "nixpkgs#devenv"
```

Verify installation:

```bash
devenv version
```

---

## 6. Grant Permissions

Various apps may need permissions:

### Input Monitoring

- Karabiner-Elements
- karabiner_grabber

### Full Disk Access (if needed)

- WezTerm (for accessing certain directories)
- Terminal.app

### Accessibility

- Apps that automate UI interactions

Check: System Preferences → Security & Privacy → Privacy

---

## Verification

After completing setup, run the test suite:

```bash
cd ~/Code/nixcfg/hosts/imac-mba-work/tests
./run-all-tests.sh
```

---

## Related Documentation

- [Main README](../README.md) - Host configuration overview
- [Test Suite](../tests/README.md) - Validation tests
- [imac0 Docs](../../imac0/docs/) - Home iMac (similar setup)
