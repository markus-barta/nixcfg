# msww87: enable-ww87 Script

## Overview

The `enable-ww87` script is a one-command solution for switching the msww87 server from testing configuration (jhw22) to production configuration at parents' home (ww87).

## Location

- **Command**: `enable-ww87` (available in PATH on msww87)
- **Source**: `hosts/msww87/configuration.nix` (systemPackages)
- **Runs from**: `~/nixcfg` directory

## What It Does

### Automatic Actions

1. ✅ Checks current location setting
2. ✅ Changes location from "jhw22" → "ww87" in configuration.nix
3. ✅ Applies the new configuration via `nixos-rebuild switch` (network reconfigures)
4. ✅ Commits and pushes the change to Git (after network is working)
5. ✅ Enables AdGuard Home (DNS server + web interface)
6. ✅ Updates network settings:
   - Gateway: 192.168.1.5 → 192.168.1.1
   - DNS: miniserver99 → local AdGuard (127.0.0.1)
   - Search domain: lan → local
7. ✅ Opens firewall ports for DNS (53) and AdGuard UI (3000)

**Important**: The script applies the configuration BEFORE committing/pushing to Git. This ensures the network gateway is reconfigured before attempting to push to GitHub.

### What It Does NOT Do (By Design)

- ❌ Does NOT enable DHCP server (left disabled for safety)
- ❌ Does NOT change static IP (remains 192.168.1.100)

## Usage

### Initial Deployment to Parents' Home

```bash
# SSH into the server (while at Markus' home)
ssh mba@192.168.1.100

# Run the script
enable-ww87

# Follow prompts, then press Enter to apply configuration
```

### After Running

- AdGuard Home web interface: http://192.168.1.100:3000
- Default credentials: admin / admin
- DNS service: Running on port 53
- DHCP: Disabled (see below to enable)

## Enabling DHCP (When Ready)

DHCP is intentionally disabled by default to prevent accidental network disruption.

### To Enable DHCP:

```bash
# Edit the configuration
nano ~/nixcfg/hosts/msww87/configuration.nix

# Find this line (around line 113):
#   enabled = false;  # TODO: Enable when ready

# Change to:
#   enabled = true;

# Save and exit (Ctrl+X, Y, Enter)

# Commit and deploy
cd ~/nixcfg
git add hosts/msww87/configuration.nix
git commit -m "feat(msww87): enable DHCP server"
git push
nixos-rebuild switch --flake .#msww87

# Verify DHCP is running
systemctl status adguardhome
ss -ulnp | grep :67
```

## Script Safety Features

1. **Idempotency**: Can be run multiple times safely - detects if already at ww87
2. **Validation**: Checks current location before making changes
3. **Confirmation**: Prompts before applying configuration
4. **Status Display**: Shows AdGuard and network status after completion
5. **Git Safety**: Commits and pushes changes to preserve history

## Reverting to jhw22 (If Needed)

To switch back to Markus' home configuration:

```bash
cd ~/nixcfg
nano hosts/msww87/configuration.nix
# Change: location = "ww87" → location = "jhw22"
git add hosts/msww87/configuration.nix
git commit -m "feat(msww87): revert to jhw22 location"
git push
nixos-rebuild switch --flake .#msww87
```

## Troubleshooting

### Script Not Found

If `enable-ww87` command is not found, rebuild the system first:

```bash
cd ~/nixcfg
nixos-rebuild switch --flake .#msww87
```

### Git Push Fails

Ensure you have SSH keys configured for GitHub:

```bash
ssh -T git@github.com
```

### AdGuard Not Starting

Check logs:

```bash
systemctl status adguardhome
journalctl -u adguardhome -n 50
```

## Related Documentation

- [msww87 README](./README.md) - Complete server documentation
- [msww87 Configuration](./configuration.nix) - NixOS configuration file
- [Archived Setup Guides](../../docs/temporary/archived/) - Historical setup documentation

---

_Created: 2025-11-16_
_Script location: `hosts/msww87/configuration.nix`_
