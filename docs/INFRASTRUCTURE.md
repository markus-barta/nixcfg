# Infrastructure

Central reference for all hosts and their relationships.

---

## Host Inventory

### NixOS Servers

| Host     | Role                      | IP            | SSH Command                    | Criticality |
| -------- | ------------------------- | ------------- | ------------------------------ | ----------- |
| **hsb0** | DNS/DHCP (AdGuard Home)   | 192.168.1.99  | `ssh mba@hsb0.lan`             | 🔴 HIGH     |
| **hsb1** | Home Automation           | 192.168.1.101 | `ssh mba@hsb1.lan`             | 🟡 MEDIUM   |
| **hsb8** | Parents' Server (offsite) | 192.168.1.100 | `ssh mba@hsb8.lan`             | 🟡 MEDIUM   |
| **csb0** | Cloud Smart Home          | 85.235.65.226 | `ssh mba@cs0.barta.cm -p 2222` | 🔴 HIGH     |
| **csb1** | Cloud Monitoring          | 152.53.64.166 | `ssh mba@cs1.barta.cm -p 2222` | 🟡 MEDIUM   |

### NixOS Desktops

| Host     | Role      | IP            | SSH Command        | Criticality |
| -------- | --------- | ------------- | ------------------ | ----------- |
| **gpc0** | Gaming PC | 192.168.1.154 | `ssh mba@gpc0.lan` | 🟢 LOW      |

### macOS Machines (home-manager only)

| Host              | Role             | User   | Git Default |
| ----------------- | ---------------- | ------ | ----------- |
| **imac0**         | Home Workstation | markus | Personal    |
| **mba-imac-work** | Work iMac        | markus | BYTEPOETS   |
| **mba-mbp-work**  | Work MacBook     | markus | BYTEPOETS   |

---

## Criticality Levels

| Level     | Meaning                                          | Examples                          |
| --------- | ------------------------------------------------ | --------------------------------- |
| 🔴 HIGH   | Network/infra depends on it, affects other hosts | hsb0 (DNS), csb0 (backup manager) |
| 🟡 MEDIUM | Important services, but isolated impact          | hsb1, csb1, hsb8                  |
| 🟢 LOW    | Personal use, no dependencies                    | gpc0, macOS machines              |

---

## Dependencies

```text
                    ┌─────────┐
                    │  hsb0   │ DNS/DHCP for all home hosts
                    │ (DNS)   │
                    └────┬────┘
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   ┌─────────┐      ┌─────────┐      ┌─────────┐
   │  hsb1   │      │  gpc0   │      │  hsb8   │
   │ (Auto)  │      │ (Game)  │      │(Parents)│
   └─────────┘      └─────────┘      └─────────┘


   ┌─────────┐           ┌─────────┐
   │  csb0   │──MQTT────▶│  csb1   │
   │ (Smart) │           │ (Mon)   │
   └────┬────┘           └─────────┘
        │
        └── Manages backups for BOTH csb0 + csb1
```

### Key Relationships

| Dependency                 | Impact if Down                              |
| -------------------------- | ------------------------------------------- |
| hsb0 → all home hosts      | DNS resolution fails, DHCP renewals fail    |
| hsb0 NCPS → all home hosts | Slower rebuilds (WAN speed), no LAN caching |
| csb0 MQTT → csb1 InfluxDB  | Metrics stop flowing to Grafana             |
| csb0 backup → csb0 + csb1  | Cleanup jobs only run on csb0               |

---

## Build Platforms

**NixOS configurations can only be built on NixOS hosts.**

| Host              | Can Build NixOS? | Speed                            | Recommended For                |
| ----------------- | ---------------- | -------------------------------- | ------------------------------ |
| **gpc0**          | ✅ Yes           | ⚡ Fastest (8 threads, i7-7700K) | Complex builds, fast iteration |
| **hsb1**          | ✅ Yes           | 🐢 Medium (4 threads)            | Remote deploys, CI             |
| **hsb0**          | ✅ Yes           | 🐢 Slow (4 threads)              | Emergency only                 |
| **imac0**         | ❌ No            | -                                | home-manager only              |
| **mba-imac-work** | ❌ No            | -                                | home-manager only              |
| **mba-mbp-work**  | ❌ No            | -                                | home-manager only              |

### Build Commands

```bash
# Build on gpc0 (fastest)
ssh mba@gpc0.lan "cd ~/Code/nixcfg && sudo nixos-rebuild test --flake .#<target>"

# Remote deploy from any machine
nixos-rebuild switch --flake .#<host> --target-host <host> --use-remote-sudo
```

---

## Cloud Server Notes (csb0, csb1)

### Netcup VPS Details

| Item           | csb0             | csb1             |
| -------------- | ---------------- | ---------------- |
| **IP**         | 85.235.65.226/22 | 152.53.64.166/24 |
| **Gateway**    | 85.235.64.1      | 152.53.64.1      |
| **SSH Port**   | 2222             | 2222             |
| **VNC Access** | Netcup SCP       | Netcup SCP       |
| **Customer #** | 227044           | 227044           |

⚠️ **csb0 subnet is /22** (not /24) — gateway is at .64.1, not .65.1

### VNC Recovery

German keyboard layout issues in Netcup VNC:

- ❌ Hyphen `-` doesn't work
- ❌ Backslash `\`, colon `:`, pipe `|` don't work
- ✅ Letters, numbers, `/`, `.`, `$`, `()`, `=`, `_` work

If login fails, use `init=/bin/sh` recovery mode (see host runbooks).

---

## Location-Aware: hsb8

hsb8 can operate at two locations with different network configs:

| Location      | Code  | Gateway     | Purpose             |
| ------------- | ----- | ----------- | ------------------- |
| Parents' home | ww87  | 192.168.1.1 | Production          |
| Markus' home  | jhw22 | 192.168.1.5 | Development/testing |

Switching requires physical access (network changes during switch).

---

## Quick SSH Aliases

These are defined in uzumaki fish config:

```bash
hsb0    # → ssh with zellij to 192.168.1.99
hsb1    # → ssh with zellij to 192.168.1.101
csb0    # → ssh with zellij to cs0.barta.cm:2222
csb1    # → ssh with zellij to cs1.barta.cm:2222
qc0     # → quick connect to csb0
qc1     # → quick connect to csb1
```

---

## NixFleet Fleet Management

### Overview

[NixFleet](https://github.com/markus-barta/nixfleet) is our in-house fleet management system for NixOS and macOS hosts. It provides:

- **Web Dashboard** for viewing all hosts and triggering deployments
- **Agent-based architecture** — devices poll for commands (works through NAT/firewalls)
- **Unified management** — same agent pattern for NixOS and macOS
- **Real-time updates** via Server-Sent Events (SSE)
- **Authentication** — password + optional TOTP (2FA)

**Dashboard URL**: `https://fleet.barta.cm` (hosted on csb1)

### Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                        NIXFLEET DASHBOARD                           │
│                      (Docker on csb1)                               │
│                     https://fleet.barta.cm                          │
│                                                                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │   FastAPI       │  │   SQLite DB     │  │   SSE Events        │  │
│  │   Backend       │  │   (hosts, cmds) │  │   (real-time)       │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │  NixOS   │    │  NixOS   │    │  macOS   │
        │  Agent   │    │  Agent   │    │  Agent   │
        │ (systemd)│    │ (systemd)│    │ (launchd)│
        └──────────┘    └──────────┘    └──────────┘

        YOUR HOME NETWORK               PARENTS' NETWORK
        (192.168.1.x)                   (192.168.1.x)
```

### Workflow

```text
┌─────────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT WORKFLOW                          │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐
  │   Cursor +   │  push   │    GitHub    │         │   NixFleet   │
  │  SYSOP Agent │ ──────► │   nixcfg     │         │  Dashboard   │
  │              │         │              │         │   (csb1)     │
  └──────────────┘         └──────────────┘         └──────┬───────┘
        │                                                  │
        │ Edit configs                                     │ Commands:
        │ Push to Git                                      │ Pull, Switch
        │                                                  │ Test
        │                                                  ▼
        │                                           ┌─────────────┐
        │                                           │   Agents    │
        │                                           │ hsb0, hsb1  │
        │                                           │ hsb8, gpc0  │
        │                                           │ imac0, etc  │
        │                                           └─────────────┘
        │
        └──── Trigger Pull + Switch from dashboard
```

### Dashboard Commands

| Command       | Description                                         |
| ------------- | --------------------------------------------------- |
| `pull`        | Run `git pull` in the config repo                   |
| `switch`      | Run `nixos-rebuild switch` or `home-manager switch` |
| `pull-switch` | Run both in sequence                                |
| `test`        | Run host test suite (`hosts/<host>/tests/T*.sh`)    |

### Why Agent-Based (Pull Model)?

| Traditional Push Model            | NixFleet Pull Model                       |
| --------------------------------- | ----------------------------------------- |
| Controller must reach each device | Devices reach out to controller           |
| Requires port forwarding / VPN    | Works through NAT automatically           |
| Firewall holes needed             | Only outbound HTTPS needed                |
| Complex for home networks         | Simple — like how your phone gets updates |

### Remote Site Management (hsb8 Example)

hsb8 at parents' house connects outbound — no VPN or port forwarding needed:

```text
Parents' Network (ww87)          Internet              Your Cloud
┌─────────────────────┐                              ┌──────────────┐
│  hsb8               │                              │    csb1      │
│  ┌──────────────┐   │                              │              │
│  │ NixFleet Agt │───┼───► HTTPS ─────────────────► │  Dashboard   │
│  └──────────────┘   │                              │              │
│                     │                              └──────────────┘
│  NAT Router         │
│  (no config needed) │
└─────────────────────┘
```

### Managed Hosts

| Host          | Type  | Location | Agent Status | Notes               |
| ------------- | ----- | -------- | ------------ | ------------------- |
| csb1          | NixOS | Cloud    | ✅ Active    | Hosts the dashboard |
| csb0          | NixOS | Cloud    | ✅ Active    | Smart home          |
| hsb0          | NixOS | Home     | 📋 Planned   | DNS/DHCP server     |
| hsb1          | NixOS | Home     | 📋 Planned   | Home automation     |
| hsb8          | NixOS | Parents  | 📋 Planned   | Parents' server     |
| gpc0          | NixOS | Home     | 📋 Planned   | Gaming PC           |
| imac0         | macOS | Home     | 📋 Planned   | Home workstation    |
| mba-imac-work | macOS | Work     | 📋 Planned   | Work iMac           |
| mba-mbp-work  | macOS | Work     | 📋 Planned   | Work MacBook        |

### NixOS vs macOS Agents

Both use the same polling mechanism. The difference is in what they execute:

| Aspect         | NixOS Hosts                 | macOS Hosts                |
| -------------- | --------------------------- | -------------------------- |
| **Agent**      | systemd service             | launchd agent              |
| **Switch cmd** | `sudo nixos-rebuild switch` | `home-manager switch`      |
| **Test suite** | `hosts/<host>/tests/T*.sh`  | `hosts/<host>/tests/T*.sh` |
| **Visibility** | Full dashboard support      | Full dashboard support     |

### Human-in-the-Loop Policy

All deployments require manual trigger from the dashboard — no auto-deploy.

| Host Type | Criticality      | Policy                      |
| --------- | ---------------- | --------------------------- |
| 🔴 HIGH   | hsb0, csb0       | Extra caution, verify first |
| 🟡 MEDIUM | hsb1, csb1, hsb8 | Standard workflow           |
| 🟢 LOW    | gpc0, macOS      | Test bed, lower risk        |

### References

- **NixFleet repo**: [nixfleet](https://github.com/markus-barta/nixfleet)
- **Dashboard deployment**: See csb1 RUNBOOK (`hosts/csb1/docs/RUNBOOK.md`)
- **Agent configuration**: NixFleet README (module options)
