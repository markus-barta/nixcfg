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

# From home (via BYTEPOETS WireGuard VPN)
ssh -p 2222 mba@10.100.0.51
```

> **Note**: mDNS (`miniserver-bp.local`) does not resolve reliably. Always use the IP directly.

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
║ 🌐 SERVICES                                                ║
║ • WireGuard VPN: 10.100.0.51 (via agenix)                 ║
║ • Jump host to office network                              ║
║ • OpenClaw Percaival: port 18789 (AI agent via Telegram)   ║
║ • pm-tool: port 8888 (placeholder)                         ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️  CURRENT STATUS                                         ║
║ • NixOS (installed 2026-01-15)                             ║
║ • SSH port 2222 + WireGuard VPN active                     ║
║ • OpenClaw Percaival running (Docker, --network=host)      ║
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

## WireGuard VPN

**Status**: ✅ **ACTIVE** (via agenix)

- Interface: `wg0`, VPN IP: `10.100.0.51/32`
- Peer: BYTEPOETS VPN server (`vpn.bytepoets.net:51820`)
- Private key: `secrets/miniserver-bp-wireguard-key.age` (managed by agenix)

### Verify

```bash
ssh -p 2222 mba@10.17.1.40 "sudo wg show"
```

### Jump Host Usage

```bash
# From home, reach office iMac via miniserver-bp
ssh -J mba@10.100.0.51:2222 markus@10.17.1.7

# Or in ~/.ssh/config:
# Host office-imac
#   HostName 10.17.1.7
#   User markus
#   ProxyJump mba@10.100.0.51:2222
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
ssh -p 2222 mba@10.17.1.40 "sudo systemctl status wireguard-wg0"

# Check logs
ssh -p 2222 mba@10.17.1.40 "sudo journalctl -xeu wireguard-wg0"

# Verify agenix decrypted the key
ssh -p 2222 mba@10.17.1.40 "sudo ls -la /run/agenix/miniserver-bp-wireguard-key"
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

### WireGuard Key Management

Private key managed via agenix (`secrets/miniserver-bp-wireguard-key.age`).
Decrypted at boot to `/run/agenix/miniserver-bp-wireguard-key` (tmpfs, never on disk).

### Hardware Limitations

Mac Mini 2009 is **old hardware**:

- No UEFI (EFI v1 only)
- 500GB HDD (not SSD)
- Limited RAM (8GB max)

**Not suitable for production workloads.** Use for testing only.

---

## Docker Services

### OpenClaw Percaival (AI Agent)

- **Container**: `openclaw-percaival` (systemd: `docker-openclaw-percaival`)
- **Port**: 18789 (Control UI + gateway)
- **Telegram**: @percaival_bot
- **Network**: `--network=host` (required, see OPENCLAW-DOCKER-SETUP.md)
- **Config**: `/var/lib/openclaw-percaival/data/openclaw.json`
- **Tools**: Brave web search, gogcli (Google Suite CLI)

```bash
# Status
sudo systemctl status docker-openclaw-percaival
docker logs -f openclaw-percaival

# Restart
sudo systemctl restart docker-openclaw-percaival

# Approve Telegram pairing
docker exec -it openclaw-percaival openclaw pairing approve telegram <CODE>
```

Full setup guide: `hosts/miniserver-bp/docs/OPENCLAW-DOCKER-SETUP.md`

### pm-tool (placeholder)

- **Container**: `pm-tool` (nginx, port 8888)
- Hello-world placeholder

---

## Related Documentation

- **OpenClaw Docker Setup**: `hosts/miniserver-bp/docs/OPENCLAW-DOCKER-SETUP.md`
- **Installation Plan**: `+pm/backlog/P8900-miniserver-bp-nixos-migration-fresh-start.md`
- **Host README**: `hosts/miniserver-bp/README.md`
- **SSH Security**: `docs/SSH-KEY-SECURITY.md`
- **Infrastructure Inventory**: `docs/INFRASTRUCTURE.md`
