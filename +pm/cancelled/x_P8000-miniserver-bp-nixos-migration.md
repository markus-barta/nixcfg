# P8000: Migrate miniserver-bp to NixOS

**Status**: BACKLOG  
**Priority**: P8 (Backlog - future enhancement)  
**Created**: 2025-12-19  
**Updated**: 2026-01-09

---

## Overview

Migrate `miniserver-bp` (Mac Mini 2009 running Ubuntu 24.04 at BYTEPOETS office) to NixOS for declarative configuration management.

**All existing services are decommissioned** - clean slate migration.

**Primary use cases**: Test-Server for local deployments of AI generated Webservices. Jump host to access e.g. `mba-imac-work` (10.17.1.7) from home via WireGuard VPN.

---

## Hardware Profile

| Item        | Value                                    |
| ----------- | ---------------------------------------- |
| **Model**   | Apple Mac Mini 3,1 (2009)                |
| **CPU**     | Intel Core 2 Duo P7350 @ 2.00GHz (2c/2t) |
| **RAM**     | 8GB                                      |
| **Storage** | 512GB SSD (7% used)                      |
| **Serial**  | YM91347119X                              |
| **MAC**     | 00:25:00:D7:6F:F6                        |
| **Uptime**  | 70+ days (stable)                        |

---

## Current Network Configuration

| Item             | Value                                 |
| ---------------- | ------------------------------------- |
| **Hostname**     | miniserver-bp (MUST NOT CHANGE)       |
| **Primary IP**   | 10.17.1.40/16 (DHCP with reservation) |
| **Interface**    | enp0s10                               |
| **Gateway**      | 10.17.1.1                             |
| **DNS**          | 1.1.1.1, 10.17.1.1                    |
| **WireGuard IP** | 10.100.0.51/32 (MUST NOT CHANGE)      |
| **VPN Endpoint** | vpn.bytepoets.net:51820               |
| **VPN Network**  | 10.100.0.0/24                         |
| **VPN DNS**      | 10.100.0.1                            |

**Critical**: Office has complex VPN setup - IP addresses and hostname must remain identical.

**Office network topology**:

- miniserver-bp: 10.17.1.40
- mba-imac-work: 10.17.1.7 (reachable from miniserver-bp)

---

## WireGuard Configuration

**VPN Details**:

- Interface: `wg0`
- Local IP: `10.100.0.51/32`
- Peer public key: `TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=`
- Endpoint: `vpn.bytepoets.net:51820`
- Allowed IPs: `10.100.0.0/24`
- DNS: `10.100.0.1`

---

## User Account Configuration

| Item                | Value                                                     |
| ------------------- | --------------------------------------------------------- |
| **Username**        | mba                                                       |
| **UID**             | 1000                                                      |
| **Shell**           | /usr/bin/fish                                             |
| **Groups**          | mba, adm, cdrom, sudo, dip, plugdev, lpadmin, lxd, docker |
| **Password hash**   | yescrypt (preserved in secrets)                           |
| **Authorized keys** | markus@iMac-5k-MBA-home.local (your SSH key)              |

---

## Access Methods

**From BYTEPOETS office (local network):**

```bash
ssh mba@miniserver-bp.local
# or
ssh mba@10.17.1.40
```

**From home (via WireGuard VPN):**

```bash
# 1. Connect to "BYTEPOETS+" VPN in WireGuard app
# 2. SSH via VPN IP
ssh mba@10.100.0.51
```

**Jump to mba-imac-work from home:**

```bash
# Via miniserver-bp as jump host
ssh -J mba@10.100.0.51 markus@10.17.1.7
# Or with ProxyJump in ~/.ssh/config
```

---

## System Configuration

| Item         | Value                                |
| ------------ | ------------------------------------ |
| **Timezone** | Europe/Vienna                        |
| **Locale**   | en_US.UTF-8 (LANG), de_AT.UTF-8 (LC) |
| **SSH Port** | 22                                   |
| **Firewall** | Inactive (office network)            |
| **NTP**      | Active, synchronized                 |

---

## Secrets Inventory (Local-Only)

All secrets stored in `hosts/miniserver-bp/secrets/` (gitignored):

| File                    | Purpose                                  | Status |
| ----------------------- | ---------------------------------------- | ------ |
| `wireguard-private.key` | WireGuard VPN private key                | ✅     |
| `id_rsa`                | mba user SSH private key                 | ✅     |
| `id_rsa.pub`            | mba user SSH public key                  | ✅     |
| `ssh_host_ed25519_key`  | SSH host key (preserves server identity) | ✅     |
| `ssh_host_rsa_key`      | SSH host key (preserves server identity) | ✅     |

**Why preserve SSH host keys?** Prevents "host key changed" warnings after migration - clients already trust these keys.

---

## Migration Strategy

### Pre-Migration (DONE)

- [x] Verify DHCP reservation exists for MAC `00:25:00:D7:6F:F6`
- [x] Document WireGuard configuration
- [x] Confirm all services are decommissioned
- [x] Extract WireGuard private key
- [x] Extract mba user SSH keypair
- [x] Extract SSH host keys (ed25519 + RSA)
- [x] Document user account (shell, groups, authorized_keys)
- [x] Document system settings (timezone, locale)
- [x] Verify jump host connectivity to mba-imac-work
- [x] Add miniserver-bp to flake.nix
- [x] Create complete configuration.nix with uzumaki/hokage

### Pre-Migration (TODO)

- [x] Create disko configuration for disk layout
- [ ] Schedule maintenance window

### NixOS Configuration (DONE)

- [x] Create `hosts/miniserver-bp/` directory structure
- [x] Create complete `configuration.nix`
- [x] Configure static IP `10.17.1.40/16`
- [x] Configure WireGuard with local-only private key file
- [x] Configure SSH with preserved host keys
- [x] Configure mba user (fish shell, groups, authorized_keys)
- [x] Set timezone/locale (Europe/Vienna, en_US.UTF-8)
- [x] Minimal server profile with uzumaki module
- [x] Integrate hokage module for consistency

### Installation Day (via nixos-anywhere)

**IMPORTANT: Installation Context**

You are on `mba-imac-work` = You are at BYTEPOETS office

- `mba-imac-work` is a 27" iMac physically located at the office
- Direct access to office network (10.17.0.0/16)
- miniserver-bp is on the same network - **no VPN needed!**

**Installation Steps:**

```bash
# Single command - nixos-anywhere handles everything!
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  --extra-files hosts/miniserver-bp/secrets \
  --chown /secrets 0:0 \
  mba@miniserver-bp.local

# What this does:
# 1. Boots into kexec installer
# 2. Partitions disk using disko config
# 3. Copies secrets to /secrets/ (owned by root)
# 4. Installs NixOS with SSH host keys preserved
# 5. Reboots into new system
# 6. WireGuard VPN works immediately

# Test SSH (no host key warning!)
ssh mba@miniserver-bp.local
```

**Alternative: From home (via WireGuard VPN)**

If you need to install from home on imac0:

```bash
# 1. Connect to "BYTEPOETS+" VPN in WireGuard app
# 2. Use VPN IP instead of .local hostname
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  --extra-files hosts/miniserver-bp/secrets \
  --chown /secrets 0:0 \
  mba@10.100.0.51
```

### Post-Migration

- [ ] Verify SSH access from office network (no host key warning)
- [ ] Verify SSH access via WireGuard VPN from home
- [ ] Test jump host to mba-imac-work: `ssh -J mba@10.100.0.51 markus@10.17.1.7`
- [ ] Verify fish shell works
- [ ] Verify uzumaki functions (pingt, helpfish, etc.)
- [ ] Run host test suite
- [ ] Update INFRASTRUCTURE.md
- [ ] Add to NixFleet (optional)

---

## nixos-anywhere Installation Method

**Better than USB!** Remote installation over SSH.

### Prerequisites

1. ✅ Added to `flake.nix`:

```nix
miniserver-bp = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage
    ./hosts/miniserver-bp/configuration.nix
  ];
};
```

2. ⏳ Create `hosts/miniserver-bp/disko-config.nix` for disk layout (optional)

### Advantages

- ✅ No physical access needed
- ✅ No USB stick required
- ✅ Can be done from office or home via VPN
- ✅ Automated installation
- ✅ Preserves SSH host keys
- ✅ Can test/retry easily
- ✅ Uses hokage + uzumaki patterns

### Risks

- ⚠️ Will wipe entire disk (backup important data first)
- ⚠️ Need working SSH access to Ubuntu system
- ⚠️ Network must stay connected during installation

### Fallback

If nixos-anywhere fails, Ubuntu is still bootable until the final reboot.

---

## NixOS Configuration Summary

**Key features:**

- Uzumaki module: fish shell, zellij, stasysmo, standard server packages
- Hokage module: consistent with other servers in fleet
- Static IP: 10.17.1.40/16
- WireGuard VPN: 10.100.0.51/32
- Preserved SSH host keys (no warnings)
- Fish shell as default
- Europe/Vienna timezone, en_US.UTF-8 + de_AT.UTF-8 locales

**Configuration checklist:**

```nix
# System identity
networking.hostName = "miniserver-bp";

# Network
networking.interfaces.enp0s10.ipv4.addresses = [{ address = "10.17.1.40"; prefixLength = 16; }];
networking.defaultGateway = "10.17.1.1";
networking.nameservers = [ "1.1.1.1" "10.17.1.1" ];

# WireGuard
networking.wireguard.interfaces.wg0 = {
  ips = [ "10.100.0.51/32" ];
  privateKeyFile = "/etc/nixos/secrets/wireguard-private.key";
  peers = [{
    publicKey = "TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=";
    endpoint = "vpn.bytepoets.net:51820";
    allowedIPs = [ "10.100.0.0/24" ];
    persistentKeepalive = 25;
  }];
};

# SSH with preserved host keys
services.openssh = {
  enable = true;
  hostKeys = [
    { path = "/etc/nixos/secrets/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/etc/nixos/secrets/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
  ];
};

# Uzumaki module
uzumaki = {
  enable = true;
  role = "server";
  fish.editor = "vim";
  stasysmo.enable = true;
};

# User
users.users.mba = {
  isNormalUser = true;
  uid = 1000;
  extraGroups = [ "wheel" "networkmanager" ];
  openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
  ];
};

# Timezone/Locale
time.timeZone = "Europe/Vienna";
i18n.defaultLocale = "en_US.UTF-8";
```

---

## Acceptance Criteria

- [ ] miniserver-bp running NixOS
- [ ] Hostname remains `miniserver-bp`
- [ ] Primary IP remains `10.17.1.40`
- [ ] WireGuard IP remains `10.100.0.51`
- [ ] SSH access working from office network (no host key warning)
- [ ] SSH access working via WireGuard VPN from home
- [ ] Jump host to mba-imac-work working
- [ ] Fish shell as default for mba user
- [ ] Uzumaki functions available (pingt, helpfish, etc.)
- [ ] Configuration in nixcfg repo
- [ ] All secrets stored locally (gitignored)
- [ ] Host tests passing
- [ ] INFRASTRUCTURE.md updated

---

## Risk Assessment

**Criticality**: 🟢 LOW (jump host only, no critical services)

**Risks**:

- Network config complexity (VPN setup)
- Old hardware (2009 Mac Mini)
- Remote installation over network

**Mitigation**:

- All secrets extracted and backed up locally
- SSH host keys preserved (no client warnings)
- Ubuntu still bootable until final reboot (fallback)
- Document exact network configuration
- Test VPN connectivity before finalizing
- Can be done from office (direct access) or home (via VPN)

---

## Notes

- All Docker containers (Naver app, Grafana, PostgreSQL, etc.) are decommissioned test installations
- GitHub Actions runner is no longer needed
- Server has been stable (70+ days uptime) but all services are unused
- mba user has SSH keypair that may be used to connect to other systems (preserved)
- Configuration uses hokage + uzumaki modules for consistency with fleet
- Installation can be done remotely via nixos-anywhere (no USB needed)
