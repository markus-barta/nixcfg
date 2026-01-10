# Infrastructure Reference

Central reference for all hosts, relationships, and configuration patterns.

---

## 🏗️ Configuration Architecture

Most hosts in this repo follow a layered configuration pattern:

1.  **Hokage (Base)**: Core system management (users, SSH, base packages, security).
2.  **Uzumaki (Personalization)**: User-specific tooling (fish, zellij, themes) and role-based defaults (server/desktop).
3.  **Host Specifics**: `configuration.nix` in the host directory for IP addresses, ZFS pools, and specific services.

### 📦 Docker Orchestration vs. NixOS

While some services are managed directly by NixOS (e.g., `openssh`, `zfs`), others run in **Docker Compose**.

**Why Docker?**

- Legacy compatibility (Node-RED flows, Mosquitto data).
- Portability between VPS providers (Netcup, Hetzner).
- Separation of concerns.

**How it's Managed**

- Compose files are stored in `hosts/<hostname>/scripts/docker-compose.yml`.
- **CRITICAL**: Do NOT manually edit files on the server.
- **Workflow**:
  1. Edit the compose file locally.
  2. Commit and push to GitHub.
  3. `git pull` on the host.
  4. `docker compose up -d`.

### 🔐 Secret Management (Agenix)

Secrets are never stored in plain text.

1.  **Agenix (Tier 1)**: Encrypted `.age` files in `secrets/`.
2.  **Decryption**: Handled by NixOS during activation.
3.  **Runtime**: Secrets appear in `/run/agenix/`.
4.  **Docker Integration**: Compose files reference `/run/agenix/<secret>` for environment variables and password files.

---

## 🚦 Traefik Architecture

Traefik acts as the global reverse proxy and edge router.

### 🔧 Components

- **NixOS Role**: Handles the `traefik` binary (if not using container) and firewall (80, 443, 8883).
- **Docker Role**: Traefik usually runs as a container to auto-discover other services via the **Docker Socket Proxy**.

### ⚙️ Configuration Patterns

1.  **Static Config** (`static.yml`): Entrypoints, providers (Docker, File), and certificate resolvers (ACME/Cloudflare).
2.  **Dynamic Config** (`dynamic.yml`): Middlewares (e.g., `cloudflarewarp`, `authelia`) and non-Docker services.
3.  **Certificates**: Managed via ACME with DNS-01 challenge (Cloudflare token).

### 🚨 Migration Note (csb0)

On `csb0`, Traefik config was historically managed via local files (`~/docker/traefik/`) not in git. These are being transitioned to Nix-managed paths or committed to the repository to prevent "directory mount" errors in Docker Compose.

---

## 🖥️ Host Inventory

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

## 📊 Relationships & Dependencies

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

## 🛠️ Build & Deployment

### Build Platforms

**NixOS configurations can only be built on NixOS hosts.**

| Host              | Can Build NixOS? | Speed                            | Recommended For                |
| ----------------- | ---------------- | -------------------------------- | ------------------------------ |
| **gpc0**          | ✅ Yes           | ⚡ Fastest (8 threads, i7-7700K) | Complex builds, fast iteration |
| **hsb1**          | ✅ Yes           | 🐢 Medium (4 threads)            | Remote deploys, CI             |
| **hsb0**          | ✅ Yes           | 🐢 Slow (4 threads)              | Emergency only                 |
| **imac0**         | ❌ No            | -                                | home-manager only              |
| **mba-imac-work** | ❌ No            | -                                | home-manager only              |
| **mba-mbp-work**  | ❌ No            | -                                | home-manager only              |

### Quick Commands

```bash
# Build on gpc0 (fastest)
ssh mba@gpc0.lan "cd ~/Code/nixcfg && sudo nixos-rebuild test --flake .#<target>"

# Remote deploy from any machine
nixos-rebuild switch --flake .#<host> --target-host <host> --use-remote-sudo
```

---

## ☁️ Cloud VPS (Netcup)

### VPS Details

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

---

## 📡 NixFleet Management

[NixFleet](https://github.com/markus-barta/nixfleet) provides centralized monitoring and push-button deployment via an agent-based pull model.

### Managed Hosts Status

| Host           | Agent Status | Notes               |
| -------------- | ------------ | ------------------- |
| **csb1**       | ✅ Active    | Hosts the dashboard |
| **csb0**       | ✅ Active    | Smart home          |
| **hsb0**       | 📋 Planned   | DNS/DHCP server     |
| **hsb1**       | 📋 Planned   | Home automation     |
| **hsb8**       | 📋 Planned   | Parents' server     |
| **gpc0**       | 📋 Planned   | Gaming PC           |
| **imac0**      | 📋 Planned   | Home workstation    |
| **macOS work** | 📋 Planned   | Work iMac/MacBook   |

---

## 🚨 Migration Notes (2026-01-10)

Modernized patterns for `csb0` transition:

- **Secrets**: Replaced local `.env` files with Agenix `/run/agenix/` secrets.
- **Data**: Moved bind mounts to persistent ZFS volumes at `/var/lib/docker/volumes/`.
- **Infrastructure**: Documented source configs for Traefik and Mosquitto from the legacy environment.
