# Runbook: miniserver-bp (Office Test Server)

**Host**: miniserver-bp (10.17.1.40) — _alias: msbp_  
**Role**: Test Server & Future Jump Host  
**Criticality**: LOW - Non-production test environment  
**Location**: BYTEPOETS Office

---

## Quick Connect

```bash
# From office network
ssh -p 2222 mba@10.17.1.40

# From home (after WireGuard setup - Phase 7)
# TBD - VPN not yet configured
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 msbp (miniserver-bp) - Office Test Server Reference     ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh -p 2222 mba@10.17.1.40                      ║
║ Alias:     msbp (preferred shorthand)                      ║
║ IP:        10.17.1.40                                      ║
║ Network:   BYTEPOETS Office LAN (10.17.0.0/16)             ║
║ Hardware:  Mac Mini Early 2009                             ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES (Planned)                                      ║
║ • WireGuard VPN: 10.100.0.51 (not yet configured)         ║
║ • Jump host to office network (future)                     ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️  CURRENT STATUS                                         ║
║ • Fresh NixOS install (2026-01-15)                         ║
║ • SSH only (port 2222)                                     ║
║ • WireGuard disabled (see Phase 7 below)                   ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. Physical access required (office only)                  ║
║ 2. Check power/network cables                              ║
║ 3. Console login: mba / <1Password recovery>               ║
╚════════════════════════════════════════════════════════════╝
```

---

## Health Checks

### Quick Status

```bash
# From office network
ssh -p 2222 mba@10.17.1.40 "uptime && df -h / | tail -1 && zpool status"
# Expected: low load, <20% disk, ZFS healthy

# Check SSH service
ssh -p 2222 mba@10.17.1.40 "systemctl status sshd --no-pager | head -10"
# Should be active (running)
```

---

## Common Tasks

### Update & Switch Configuration

```bash
# From mba-imac-work or any office machine
ssh -p 2222 mba@10.17.1.40

# On miniserver-bp:
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#miniserver-bp
```

### Rollback

```bash
# If last switch broke something
ssh -p 2222 mba@10.17.1.40
sudo nixos-rebuild switch --rollback

# Or boot into previous generation via GRUB (physical access)
```

### Check System Info

```bash
ssh -p 2222 mba@10.17.1.40 "nixos-version && uname -a"
```

---

## Phase 7: WireGuard VPN Setup (Post-Install)

**Status**: ⏳ **NOT YET CONFIGURED**

**Goal**: Enable WireGuard for remote access from home to office network.

### Prerequisites

Before starting, you need the WireGuard private key from the old Ubuntu installation.

**If you have Ubuntu backup**:

```bash
# Extract private key from Ubuntu backup
# (stored somewhere safe before wiping)
cat /backup/ubuntu-wireguard/privatekey
```

**If no backup available**:

You'll need to generate a new key pair and update the BYTEPOETS VPN server:

```bash
# Generate new keypair
wg genkey | tee privatekey | wg pubkey > publickey

# Send public key to BYTEPOETS VPN admin to update server config
```

### Step 1: Copy Private Key to miniserver-bp

```bash
# From your machine with the private key
ssh -p 2222 mba@10.17.1.40

# On miniserver-bp:
sudo mkdir -p /etc/nixos/secrets
sudo chmod 700 /etc/nixos/secrets

# Create the private key file (paste the key when prompted)
sudo nano /etc/nixos/secrets/wireguard-private.key
# Paste the private key, save (Ctrl+O, Enter, Ctrl+X)

# Secure the file
sudo chmod 600 /etc/nixos/secrets/wireguard-private.key
sudo chown root:root /etc/nixos/secrets/wireguard-private.key
```

### Step 2: Enable WireGuard in Configuration

```bash
# On your workstation (mba-imac-work)
cd ~/Code/nixcfg

# Edit hosts/miniserver-bp/configuration.nix
# Uncomment lines 78-93 (WireGuard section)
nano hosts/miniserver-bp/configuration.nix

# Commit the change
git add hosts/miniserver-bp/configuration.nix
git commit -m "Enable WireGuard VPN on miniserver-bp"

# Push to GitHub (if using NixFleet) or apply directly
git push
```

### Step 3: Apply Configuration

```bash
# On miniserver-bp:
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#miniserver-bp
```

### Step 4: Verify WireGuard

```bash
# On miniserver-bp:
sudo wg show
# Expected output:
# interface: wg0
#   public key: <your public key>
#   private key: (hidden)
#   listening port: <random>
#
# peer: TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=
#   endpoint: vpn.bytepoets.net:51820
#   allowed ips: 10.100.0.0/24
#   latest handshake: <timestamp>
#   transfer: <stats>

# Test from home (via VPN):
ping 10.100.0.51
ssh -p 2222 mba@10.100.0.51
```

### Step 5: Test Jump Host Functionality

```bash
# From home, connect to office iMac via miniserver-bp jump host
ssh -J mba@10.100.0.51:2222 markus@10.17.1.7

# Or configure ~/.ssh/config for easier access:
# Host office-imac
#   HostName 10.17.1.7
#   User markus
#   ProxyJump mba@10.100.0.51:2222
#
# Then: ssh office-imac
```

---

## Troubleshooting

### SSH Connection Refused

**Problem**: `ssh: connect to host 10.17.1.40 port 22: Connection refused`

**Solution**: Use port **2222**, not 22:

```bash
ssh -p 2222 mba@10.17.1.40
```

### Wrong Port in Config?

**Check**: Verify SSH port in configuration:

```bash
ssh -p 2222 mba@10.17.1.40 "sudo grep 'services.openssh' /etc/nixos/configuration.nix -A 10"
```

Expected: No custom port set (defaults to 22 in NixOS, but hokage module sets 2222 for server-remote role).

### WireGuard Not Starting

```bash
# Check WireGuard service status
ssh -p 2222 mba@10.17.1.40 "sudo systemctl status wg-quick-wg0"

# Check logs
ssh -p 2222 mba@10.17.1.40 "sudo journalctl -xeu wg-quick-wg0"

# Verify private key exists
ssh -p 2222 mba@10.17.1.40 "sudo ls -la /etc/nixos/secrets/wireguard-private.key"
```

### Fonts Missing on Console

**This is normal for headless servers.** Fonts are only needed for GUI environments.

If you see font warnings during console login, they can be safely ignored - SSH terminals render fonts on the client side.

### ZFS Pool Issues

```bash
# Check ZFS pool status
ssh -p 2222 mba@10.17.1.40 "sudo zpool status"

# Check disk health
ssh -p 2222 mba@10.17.1.40 "sudo smartctl -a /dev/sda"
```

---

## Recovery Procedures

### Lost SSH Access

1. **Physical access required** (machine is in office)
2. Login at console: `mba` / `<1Password recovery password>`
3. Check SSH service: `sudo systemctl status sshd`
4. Start SSH if stopped: `sudo systemctl start sshd`
5. Check firewall: `sudo iptables -L -n | grep 2222`

### Boot Failure

1. Physical access to machine
2. GRUB menu → Select previous generation
3. Boot into working config
4. Investigate: `journalctl -b -1` (previous boot)

### Complete System Failure

**Reinstall using nixos-anywhere** (same as initial install):

```bash
# Boot from minimal NixOS USB stick
# User: nixos, Password: 1234

# From mba-imac-work:
cd ~/Code/nixcfg

nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  nixos@10.17.1.40
```

See `+pm/backlog/P8900-miniserver-bp-nixos-migration-fresh-start.md` for full procedure.

---

## Security

### SSH Keys

Same authorized keys as csb0/csb1:

- markus@iMac-5k-MBA-home.local (id_rsa)

**Recovery password**: Stored in 1Password ("csb0 csb1 recovery")

### Password Authentication

**Enabled** for emergency recovery (learned from hsb1 lockout incident).

Can be disabled after verifying SSH key access works:

```nix
# In configuration.nix:
services.openssh.settings.PasswordAuthentication = false;
```

---

## Maintenance

### Regular Tasks

- ⏳ **Never**: This is a test server, not production
- ✅ **As needed**: Test new configurations before deploying to production hosts

### Monitoring

Not monitored by NixFleet or other systems (intentional - test server only).

---

## Notes

### Installation Date

**2026-01-15** - Fresh NixOS install via nixos-anywhere

### Why Port 2222?

Hokage module (`github:pbek/nixcfg`) sets SSH to port 2222 for `server-remote` role (security hardening).

### Why No WireGuard Initially?

To simplify initial installation and avoid secrets management during nixos-anywhere.

WireGuard can be enabled manually after verifying base system works (Phase 7 above).

### Hardware Limitations

Mac Mini 2009 is **old hardware**:

- No UEFI (EFI v1 only)
- 500GB HDD (not SSD)
- Limited RAM (8GB max)

**Not suitable for production workloads.** Use for testing only.

---

## Related Documentation

- **Installation Plan**: `+pm/backlog/P8900-miniserver-bp-nixos-migration-fresh-start.md`
- **Host README**: `hosts/miniserver-bp/README.md`
- **SSH Security**: `docs/SSH-KEY-SECURITY.md`
- **Infrastructure Inventory**: `docs/INFRASTRUCTURE.md`
