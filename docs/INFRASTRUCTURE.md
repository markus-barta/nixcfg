# Infrastructure

Central reference for all hosts and their relationships.

---

## Host Inventory

### NixOS Servers

| Host     | Role                    | IP            | SSH Command                    | Criticality |
| -------- | ----------------------- | ------------- | ------------------------------ | ----------- |
| **hsb0** | DNS/DHCP (AdGuard Home) | 192.168.1.99  | `ssh mba@hsb0.lan`             | 🔴 HIGH     |
| **hsb1** | Home Automation         | 192.168.1.101 | `ssh mba@hsb1.lan`             | 🟡 MEDIUM   |
| **hsb8** | Parents' Server         | 192.168.1.100 | `ssh mba@hsb8.lan`             | 🟡 MEDIUM   |
| **csb0** | Cloud Smart Home        | 85.235.65.226 | `ssh mba@cs0.barta.cm -p 2222` | 🔴 HIGH     |
| **csb1** | Cloud Monitoring        | 152.53.64.166 | `ssh mba@cs1.barta.cm -p 2222` | 🟡 MEDIUM   |
| **gpc0** | Gaming PC               | 192.168.1.154 | `ssh mba@gpc0.lan`             | 🟢 LOW      |

### macOS Machines (home-manager only)

| Host              | Role             | User   | Git Default |
| ----------------- | ---------------- | ------ | ----------- |
| **imac0**         | Home Workstation | markus | Personal    |
| **imac-mba-work** | Work iMac        | markus | BYTEPOETS   |
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

```
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

| Dependency                | Impact if Down                           |
| ------------------------- | ---------------------------------------- |
| hsb0 → all home hosts     | DNS resolution fails, DHCP renewals fail |
| csb0 MQTT → csb1 InfluxDB | Metrics stop flowing to Grafana          |
| csb0 backup → csb0 + csb1 | Cleanup jobs only run on csb0            |

---

## Build Platforms

**NixOS configurations can only be built on NixOS hosts.**

| Host              | Can Build NixOS? | Speed                            | Recommended For                |
| ----------------- | ---------------- | -------------------------------- | ------------------------------ |
| **gpc0**          | ✅ Yes           | ⚡ Fastest (8 threads, i7-7700K) | Complex builds, fast iteration |
| **hsb1**          | ✅ Yes           | 🐢 Medium (4 threads)            | Remote deploys, CI             |
| **hsb0**          | ✅ Yes           | 🐢 Slow (4 threads)              | Emergency only                 |
| **imac0**         | ❌ No            | -                                | home-manager only              |
| **imac-mba-work** | ❌ No            | -                                | home-manager only              |
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
