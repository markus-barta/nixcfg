# Runbook: imac-mba-work (Work Workstation)

**Host**: imac-mba-work  
**Role**: Work macOS development workstation (BYTEPOETS)  
**OS**: macOS Sequoia + Nix + home-manager  
**Criticality**: LOW - Work workstation

---

## Quick Reference

| Item            | Value                       |
| --------------- | --------------------------- |
| **Hostname**    | `imac-mba-work`             |
| **Model**       | iMac 27" (2019)             |
| **CPU**         | Intel i9-9900K (16 threads) |
| **RAM**         | 16 GB                       |
| **User**        | `markus`                    |
| **Config**      | home-manager (standalone)   |
| **Git Default** | Work identity (BYTEPOETS)   |

---

## Common Tasks

### Update Configuration

```bash
cd ~/Code/nixcfg
git pull
just switch
# OR
home-manager switch --flake ".#markus@imac-mba-work"
```

### Update Flake Inputs

```bash
cd ~/Code/nixcfg
nix flake update
just switch
```

---

## Troubleshooting

### Commands Not Found After Switch

```bash
# Restart shell
exec fish

# Check PATH priority
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

### devenv / direnv Issues

#### "devenv: command not found"

```bash
# Install devenv
nix profile install "nixpkgs#devenv"
```

#### "use_devenv: command not found"

```bash
cd ~/Code/nixcfg
direnv allow
direnv reload
```

#### ".shared/common.just" import error

```bash
# Let devenv create the file
cd ~/Code/nixcfg
devenv shell -- echo "Shell loaded"
```

### Nix Cache / Slow Builds

If builds are slow (compiling from source):

```bash
# Edit /etc/nix/nix.conf
sudo nano /etc/nix/nix.conf

# Add:
trusted-users = root markus

# Restart nix-daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

### Git Wrong Identity

```bash
# Check current identity
git config user.email

# Should auto-switch:
# Default → markus.barta@bytepoets.com (work)
# ~/Code/nixcfg → markus@barta.com (personal)
```

### Karabiner Not Working

1. Check Karabiner-Elements is running (menu bar)
2. System Preferences → Security & Privacy → Privacy → Input Monitoring
3. Enable "karabiner_grabber" and "Karabiner-Elements"

```bash
killall karabiner_console_user_server
```

---

## Key Paths

```bash
# Configuration
~/Code/nixcfg/hosts/imac-mba-work/home.nix

# Scripts
~/Scripts/                    # Symlinked from hosts/imac-mba-work/scripts/host-user/

# Karabiner config
~/.config/karabiner/karabiner.json
```

---

## Differences from imac0 (Home)

| Feature         | imac0 (Home)      | imac-mba-work (Work)      |
| --------------- | ----------------- | ------------------------- |
| **Git Default** | Personal identity | Work identity (BYTEPOETS) |
| **esptool**     | ✅ Installed      | ❌ Not needed             |
| **nmap**        | ✅ Installed      | ❌ Not needed             |

---

## Useful Commands

```bash
# Apply configuration
just switch                 # Platform-aware switch
just home-switch            # Explicit home-manager switch

# Update everything
just update                 # Update flake inputs
just upgrade                # Update + switch

# devenv management
devenv shell                # Enter development shell
devenv update               # Update devenv.lock

# System info
nix --version               # Nix version
home-manager --version      # home-manager version
which fish git node python3 # Verify Nix binaries

# Troubleshooting
direnv reload               # Reload environment
exec fish                   # Restart shell
```

---

## Package Managers

| Manager      | Purpose                        | Count                   |
| ------------ | ------------------------------ | ----------------------- |
| **Nix**      | CLI tools, shell, interpreters | ~37 packages            |
| **Homebrew** | GUI apps, multimedia           | ~110 formulae + 4 casks |

---

## Related Documentation

- [imac-mba-work README](../README.md) - Full workstation documentation
- [SECRETS.md](../secrets/SECRETS.md) - Credentials (gitignored)
- [Tests](../tests/README.md) - Validation test suite
- [imac0 README](../../imac0/README.md) - Home iMac (similar config)
