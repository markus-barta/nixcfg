# Runbook: imac0 (Home Workstation)

**Host**: imac0 (192.168.1.150)  
**Role**: Personal macOS development workstation  
**OS**: macOS Sequoia + Nix + home-manager  
**Criticality**: LOW - Personal workstation

---

## Quick Reference

| Item           | Value                       |
| -------------- | --------------------------- |
| **Hostname**   | `imac0`                     |
| **IP Address** | `192.168.1.150`             |
| **Model**      | iMac 27" 5K (2019)          |
| **CPU**        | Intel i9-9900K (16 threads) |
| **RAM**        | 16 GB                       |
| **User**       | `markus`                    |
| **Config**     | home-manager (standalone)   |

---

## Common Tasks

### Update Configuration

```bash
cd ~/Code/nixcfg
git pull
home-manager switch --flake ".#markus@imac0"
# OR
just switch
```

### Update Flake Inputs

```bash
cd ~/Code/nixcfg
nix flake update
home-manager switch --flake ".#markus@imac0"
```

---

## Troubleshooting

### Commands Not Found After Switch

```bash
# Restart shell
exec fish

# Or check PATH
echo $PATH | tr ':' '\n' | head -5
# Should show ~/.nix-profile/bin first
```

### Karabiner Not Working

1. Check Karabiner-Elements is running (menu bar)
2. System Preferences → Security & Privacy → Privacy → Input Monitoring
3. Enable "karabiner_grabber" and "Karabiner-Elements"

```bash
# Restart Karabiner
killall karabiner_console_user_server
```

### Nerd Font Icons Missing

```bash
# Check font installation
fc-list | grep "Hack Nerd"

# Restart font daemon
killall fontd
```

### Git Wrong Identity

```bash
# Check current identity
git config user.email

# Should auto-switch based on directory:
# ~/Code/nixcfg → markus@barta.com (personal)
# ~/Code/BYTEPOETS/ → markus.barta@bytepoets.com (work)
```

---

## Key Paths

```bash
# Configuration
~/Code/nixcfg/hosts/imac0/home.nix

# Scripts
~/Scripts/                    # Symlinked from hosts/imac0/scripts/host-user/

# Karabiner config
~/.config/karabiner/karabiner.json  # Symlinked from hosts/imac0/config/
```

---

## System Information

```bash
# System info
system_profiler SPHardwareDataType
sw_vers

# Disk usage
df -h / /nix

# Nix info
nix --version
home-manager --version
```

---

## Useful Commands

```bash
# home-manager rebuild
just switch

# Flush DNS cache
flushdns

# Network commands use macOS native (not Nix)
ping google.com               # Uses /sbin/ping

# SSH to servers (with zellij)
hsb0                          # → ssh mba@192.168.1.99 with zellij
hsb1                          # → ssh mba@192.168.1.101 with zellij
csb0                          # → ssh mba@cs0.barta.cm:2222 with zellij
csb1                          # → ssh mba@cs1.barta.cm:2222 with zellij
```

---

## Manual Installs (not in Nix or Homebrew)

| App                  | Source                                                                          | Notes                                                                                                                                                                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Syntax Highlight** | [GitHub releases](https://github.com/sbarex/SourceCodeSyntaxHighlight/releases) | Quick Look extension for source files. Brew cask deprecated (Gatekeeper). Download zip, unpack to `/Applications/`, run `xattr -cr` to clear quarantine. Has Sparkle auto-update. Enable QL extension in System Settings > Privacy & Security > Extensions. |

---

## Package Managers

| Manager      | Purpose                            | Count         |
| ------------ | ---------------------------------- | ------------- |
| **Nix**      | CLI tools, shell, interpreters     | ~45 packages  |
| **Homebrew** | GUI apps, multimedia, system tools | ~130 packages |

### Key Binaries (Nix)

```bash
which fish git node python3 starship wezterm bat rg fd
# All should show ~/.nix-profile/bin/...
```

---

## Related Documentation

- [imac0 README](../README.md) - Full workstation documentation
- [SECRETS.md](../secrets/SECRETS.md) - Credentials (gitignored)
- [Manual Setup](./manual-setup/) - One-time configuration steps
- [Progress & History](./progress.md) - Migration status
