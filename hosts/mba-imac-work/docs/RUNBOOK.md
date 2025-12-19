# Runbook: mba-imac-work (Work Workstation)

**Host**: mba-imac-work  
**Role**: Work macOS development workstation (BYTEPOETS)  
**OS**: macOS Sequoia + Nix + home-manager  
**Criticality**: LOW - Work workstation

---

## Quick Reference

| Item            | Value                       |
| --------------- | --------------------------- |
| **Hostname**    | `mba-imac-work`             |
| **Model**       | iMac 27" (2019)             |
| **CPU**         | Intel i9-9900K (16 threads) |
| **RAM**         | 16 GB                       |
| **User**        | `markus`                    |
| **Config**      | home-manager (standalone)   |
| **Git Default** | Work identity (BYTEPOETS)   |

---

## Remote Access

The iMac is on the BYTEPOETS internal network. To access remotely:

### Network Topology

```
Home → WireGuard VPN ("BYTEPOETS+") → 10.100.0.x (VPN subnet)
                                    → miniserver-bp (10.100.0.51) [Ubuntu]
                                                   → Internal network (10.17.1.x)
                                                   → mba-imac-work (10.17.1.7)
```

### Access from Home (Step-by-Step)

1. **Connect to VPN**: Open WireGuard app on macOS → Select "BYTEPOETS+" → Activate
2. **SSH to miniserver-bp** (Ubuntu jump host):
   ```bash
   ssh mba@10.100.0.51
   ```
3. **SSH to mba-imac-work** from miniserver-bp:
   ```bash
   ssh markus@10.17.1.7
   ```

**Or in one command** (jump host):

```bash
ssh -J mba@10.100.0.51 markus@10.17.1.7
```

### SSH Key Setup (Passwordless Access)

To avoid password prompts when SSHing from miniserver-bp to mba-imac-work:

```bash
# On miniserver-bp, copy the SSH key to mba-imac-work
ssh-copy-id markus@10.17.1.7

# Verify passwordless access
ssh markus@10.17.1.7 "echo 'SSH key auth working!'"
```

If `ssh-copy-id` is not available on miniserver-bp:

```bash
# Manual method: append your public key to authorized_keys
cat ~/.ssh/id_rsa.pub | ssh markus@10.17.1.7 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### mDNS Access

From miniserver-bp, mDNS also works:

```bash
ssh markus@mba-imac-work.local
```

### Important Notes

- The iMac sleeps when inactive and may not be reachable
- When it wakes up, mDNS (`mba-imac-work.local`) should resolve
- The NixFleet agent runs and will reconnect automatically when awake
- **miniserver-bp** runs Ubuntu 24.04 (future: migrate to NixOS - see backlog)

### NixFleet Agent

The NixFleet agent runs as a launchd agent and reports to `fleet.barta.cm`.

```bash
# Check agent status
tail -20 /tmp/nixfleet-agent.log

# Restart agent
launchctl kickstart -k gui/$(id -u)/com.nixfleet.agent

# View launchd plist
cat ~/Library/LaunchAgents/com.nixfleet.agent.plist
```

---

## Common Tasks

### Update Configuration

```bash
cd ~/Code/nixcfg
git pull
just switch
# OR
home-manager switch --flake ".#markus@mba-imac-work"
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
~/Code/nixcfg/hosts/mba-imac-work/home.nix

# Scripts
~/Scripts/                    # Symlinked from hosts/mba-imac-work/scripts/host-user/

# Karabiner config
~/.config/karabiner/karabiner.json
```

---

## Differences from imac0 (Home)

| Feature         | imac0 (Home)      | mba-imac-work (Work)      |
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

- [mba-imac-work README](../README.md) - Full workstation documentation
- [SECRETS.md](../secrets/SECRETS.md) - Credentials (gitignored)
- [Tests](../tests/README.md) - Validation test suite
- [imac0 README](../../imac0/README.md) - Home iMac (similar config)
