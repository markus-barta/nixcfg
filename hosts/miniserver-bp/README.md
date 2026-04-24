# msbp (miniserver-bp) - Mac Mini 2009 Test Server

> **Host Alias**: `msbp` (preferred shorthand for "miniserver-bp")
>
> **⚠️ MIGRATION TODO (2026-04-15):** `msbp` will eventually move to the
> BYTEPOETS-owned `bpnixcfg` repo (`/Users/markus/Code/bpnixcfg`, remote
> `github:BYTEPOETS/bpnixcfg`). Scope: drop the external
> `inputs.nixcfg = "github:pbek/nixcfg"` dependency, switch imports from
> `hokage.*` to the in-tree `bpnixcore` module that lives there.
> **Not urgent** — this host keeps running here until the bonelio hosts
> are live and `bpnixcore` is battle-tested on real infra. Do not touch
> the NixOS config here until then. See `modules/bpnixcore/DESIGN.md`
> in the bpnixcfg repo for the migration story.

**Status**: ✅ Running (Hokage + Uzumaki)
**Type**: Office Server (Mac Mini Early 2009)
**OS**: NixOS 26.05 (Yarara)
**Config**: External Hokage (`github:pbek/nixcfg`) + Uzumaki modules
**Location**: BYTEPOETS Office
**Last Deploy**: 2026-02-12

---

## Quick Reference

| Item         | Value                                 |
| ------------ | ------------------------------------- |
| **Hostname** | miniserver-bp                         |
| **IP (v4)**  | 10.17.1.40                            |
| **SSH**      | `ssh -p 2222 mba@10.17.1.40`          |
| **Network**  | BYTEPOETS Office LAN (10.17.0.0/16)   |
| **Hardware** | Mac Mini Early 2009 (Core 2 Duo, 8GB) |
| **Storage**  | 500GB HDD (ZFS)                       |

---

## ⚠️ Current Role

| Service       | Status      | Port  | Purpose                                    |
| ------------- | ----------- | ----- | ------------------------------------------ |
| **SSH**       | ✅ Running  | 2222  | Remote access                              |
| **pm-tool**   | ✅ Running  | 8888  | PM tool (hello-world placeholder)          |
| **OpenClaw**  | ✅ Running  | 18789 | AI agent (Percaival) — Telegram, M365, gog |
| **Docker**    | ✅ Running  | —     | Container runtime                          |
| **WireGuard** | ❌ Disabled | —     | VPN (planned - see Phase 7)                |

**Primary Use**: Test server for NixOS experiments, pm-tool, and OpenClaw AI agent.

**Future**: WireGuard jump host for remote access to office network.

---

## Folder Structure

```
hosts/miniserver-bp/
├── configuration.nix          # Main NixOS configuration (Hokage)
├── hardware-configuration.nix # Auto-generated hardware config
├── disk-config.zfs.nix        # Disko ZFS layout
├── README.md                  # This file
│
└── docs/                      # 📚 Documentation
    └── RUNBOOK.md             # Operational procedures
```

---

## Services

Currently minimal - SSH only.

Planned services:

- WireGuard VPN (jump host functionality)
- Test deployments for new configurations

---

## Common Operations

### SSH Access

```bash
# From office network
ssh -p 2222 mba@10.17.1.40

# From home (after WireGuard setup)
# TBD - see docs/RUNBOOK.md Phase 7
```

### Update Configuration

```bash
# From any machine with nixcfg repo
cd ~/Code/nixcfg

# Build remotely (don't build on macOS!)
ssh mba@10.17.1.40 -p 2222 "cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#miniserver-bp"
```

### Rollback

```bash
# Via SSH
ssh -p 2222 mba@10.17.1.40
sudo nixos-rebuild switch --rollback
```

---

## Installation History

**Method**: nixos-anywhere (fresh install from minimal NixOS USB)

**Date**: 2026-01-15

**Changes from Ubuntu**:

- Fresh NixOS install (no migration)
- ZFS filesystem (disko)
- SSH port changed: 22 → 2222
- WireGuard temporarily disabled

Migration planning is tracked in PPM; see the relevant `NIX-*` issue for the full migration plan.

---

## Network

### Static IP Configuration

| Setting        | Value                  |
| -------------- | ---------------------- |
| **IP Address** | `10.17.1.40/16`        |
| **Gateway**    | `10.17.1.1`            |
| **DNS**        | `1.1.1.1`, `10.17.1.1` |
| **Interface**  | `enp0s10` (static)     |

### SSH (Hardened)

- Port: **2222** (not 22)
- Password auth: Enabled (recovery fallback)
- Root login: Disabled
- Key auth: Primary method (same keys as csb0/csb1)

### Firewall

| Port | Service | Access     |
| ---- | ------- | ---------- |
| 2222 | SSH     | Open       |
| 8888 | pm-tool | Open       |
| 22   | SSH     | **Closed** |

---

## Hardware Specs

| Component   | Specification                     |
| ----------- | --------------------------------- |
| **CPU**     | Intel Core 2 Duo P8700 @ 2.53 GHz |
| **RAM**     | 8 GB DDR3                         |
| **Storage** | 500 GB HDD (ZFS)                  |
| **Network** | Gigabit Ethernet                  |
| **Year**    | Early 2009                        |

---

## Emergency

See `docs/RUNBOOK.md` for:

- Recovery procedures
- WireGuard setup (Phase 7)
- Troubleshooting

---

## Related Hosts

- **mba-imac-work**: Primary office workstation
- **gpc0**: Build host (fastest for remote builds)
- **csb0/csb1**: Cloud servers (same SSH key pattern)

---

## SSH Fingerprints

```bash
# Run on server to get fingerprints:
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub
```

(Fresh keys generated on 2026-01-15, not preserved from Ubuntu)
