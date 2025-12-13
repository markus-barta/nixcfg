# Runbook: mba-mbp-work (Work MacBook Pro)

**Host**: mba-mbp-work (192.168.1.237)  
**Role**: Work macOS laptop (BYTEPOETS)  
**OS**: macOS Sequoia + Nix + home-manager  
**Criticality**: MEDIUM - Work laptop

---

## Quick Reference

| Item           | Value                                 |
| -------------- | ------------------------------------- |
| **Hostname**   | `mba-mbp-work`                        |
| **IP Address** | `192.168.1.237`                       |
| **Model**      | MacBook Pro 15,2 (2018 13" Touch Bar) |
| **CPU**        | Quad-Core Intel i5 @ 2.3 GHz          |
| **RAM**        | 16 GB                                 |
| **User**       | `mba`                                 |
| **Config**     | home-manager (standalone)             |

---

## Common Tasks

### Update Configuration

```bash
cd ~/Code/nixcfg
git pull
home-manager switch --flake ".#mba@mba-mbp-work"
# OR
just switch
```

### Update Flake Inputs (including nixfleet agent)

```bash
cd ~/Code/nixcfg
nix flake update nixfleet
home-manager switch --flake ".#mba@mba-mbp-work"
```

### Update All Flake Inputs

```bash
cd ~/Code/nixcfg
nix flake update
home-manager switch --flake ".#mba@mba-mbp-work"
```

---

## SSH Access

### From Any Machine on Local Network

```bash
# Using mDNS (recommended - works even if IP changes)
ssh mba@mba-mbp-work.local

# Using fish alias (from imac0)
mbpw

# Or directly by IP
ssh mba@192.168.1.237
```

### Enable Remote Login (if disabled)

System Preferences → Sharing → Remote Login → On

---

## NixFleet Agent

### Check Agent Status

```bash
launchctl list | grep nixfleet
# Should show: PID  0  com.nixfleet.agent
```

### View Agent Logs

```bash
# Stdout log
tail -50 /tmp/nixfleet-agent.log

# Stderr log
tail -50 /tmp/nixfleet-agent.err
```

### Restart Agent

```bash
launchctl kickstart -k gui/$(id -u)/com.nixfleet.agent
```

### Reload Agent (after config change)

```bash
launchctl bootout gui/$(id -u)/com.nixfleet.agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nixfleet.agent.plist
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

### Agent Not Running

```bash
# Check if plist exists
ls ~/Library/LaunchAgents/com.nixfleet.agent.plist

# Load agent
launchctl load ~/Library/LaunchAgents/com.nixfleet.agent.plist

# Verify running
launchctl list | grep nixfleet
```

### Git Wrong Identity

```bash
# Check current identity
git config user.email

# Should auto-switch based on directory:
# ~/Code/nixcfg → markus@barta.com (personal)
# ~/Code/BYTEPOETS/ → markus.barta@bytepoets.com (work)
```

### flake.lock Conflicts

```bash
cd ~/Code/nixcfg
git checkout -- flake.lock
git pull
```

---

## Key Paths

```bash
# Configuration
~/Code/nixcfg/hosts/mba-mbp-work/home.nix

# Scripts
~/Scripts/                    # Symlinked from hosts/mba-mbp-work/scripts/host-user/

# Agent logs
/tmp/nixfleet-agent.log       # Stdout
/tmp/nixfleet-agent.err       # Stderr

# Agent plist
~/Library/LaunchAgents/com.nixfleet.agent.plist
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

# Agent version
cat ~/Library/LaunchAgents/com.nixfleet.agent.plist | grep -A1 AGENT_VERSION
```

---

## Useful Commands

```bash
# home-manager rebuild
just switch

# Flush DNS cache
flushdns

# SSH to servers (with zellij)
hsb0                          # → ssh mba@192.168.1.99 with zellij
hsb1                          # → ssh mba@192.168.1.101 with zellij
csb0                          # → ssh mba@cs0.barta.cm:2222 with zellij
csb1                          # → ssh mba@cs1.barta.cm:2222 with zellij
```

---

## Related Documentation

- [mba-mbp-work README](../README.md) - Full laptop documentation
- [Initial Setup](./INITIAL-SETUP.md) - First-time configuration
- [imac0 Runbook](../../imac0/docs/RUNBOOK.md) - Similar macOS setup
