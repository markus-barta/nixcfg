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

| Host     | Role                                | IP            | SSH Command                    | Criticality |
| -------- | ----------------------------------- | ------------- | ------------------------------ | ----------- |
| **hsb0** | DNS/DHCP + Merlin (OpenClaw Docker) | 192.168.1.99  | `ssh mba@hsb0.lan`             | 🔴 HIGH     |
| **hsb1** | Home Automation                     | 192.168.1.101 | `ssh mba@hsb1.lan`             | 🟡 MEDIUM   |
| **hsb8** | Parents' Server (offsite)           | 192.168.1.100 | `ssh mba@hsb8.lan`             | 🟡 MEDIUM   |
| **csb0** | Cloud Smart Home                    | 85.235.65.226 | `ssh mba@cs0.barta.cm -p 2222` | 🔴 HIGH     |
| **csb1** | Cloud Monitoring                    | 152.53.64.166 | `ssh mba@cs1.barta.cm -p 2222` | 🟡 MEDIUM   |

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

## 🔗 SSH Host Nicknames

Shorter aliases for commonly accessed hosts:

| Nickname | Full Hostname | Purpose          | Tailscale Address |
| -------- | ------------- | ---------------- | ----------------- |
| `mbpw`   | mba-mbp-work  | Work MacBook Pro | mbpw.ts.barta.cm  |
| `imacw`  | mba-imac-work | Work iMac        | imacw.ts.barta.cm |
| `hsb0`   | hsb0          | Home DNS/DHCP    | hsb0.ts.barta.cm  |
| `hsb1`   | hsb1          | Home Automation  | hsb1.ts.barta.cm  |
| `csb0`   | csb0          | Cloud Smart Home | csb0.ts.barta.cm  |

### SSH Connection Examples

```bash
# 🌐 From ANYWHERE (recommended - works from home, work, coffee shop)
ssh mba@hsb1.ts.barta.cm

# Using nickname (for local machines)
ssh mbpw

# Force specific route
ssh mbpw-lan    # LAN only (fail if unreachable)
ssh mbpw-ts     # Tailscale only

# Auto-fallback (default)
ssh mbpw        # Try LAN first (2s timeout), fallback to Tailscale
```

### How LAN→Tailscale Fallback Works

1. **At home/office:** Connects via LAN (fast, direct)
2. **Remote/coffee shop:** Auto-fallbacks to Tailscale after 2s
3. **Zellij integration:** All aliases include `zellij attach` for session persistence

**🌐 Pro tip:** Always use Tailscale addresses (`*.ts.barta.cm`) when away from home/office network.

**Note:** SSH config is declaratively managed in `modules/shared/ssh-fleet.nix`.

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
| hsb0 Merlin → hsb1         | Merlin loses SSH access to HA/Node-RED      |
| csb0 MQTT → csb1 InfluxDB  | Metrics stop flowing to Grafana             |
| csb0 backup → csb0 + csb1  | Cleanup jobs only run on csb0               |

---

## 🔗 Headscale VPN (Mesh Network - Access from ANYWHERE)

Self-hosted Tailscale control server on csb0. Provides mesh VPN across all hosts - **reachable from anywhere with internet**.

- **Control server**: `https://hs.barta.cm` (csb0, Docker)
- **MagicDNS domain**: `ts.barta.cm` (hosts addressable as `<hostname>.ts.barta.cm`)
- **IP range**: `100.64.0.0/10`
- **Server docs**: See `hosts/csb0/docs/RUNBOOK.md` → Headscale section

### Why Use Tailscale?

| From Location  | LAN (.lan)       | Internet (barta.cm) | Tailscale (ts.barta.cm) |
| -------------- | ---------------- | ------------------- | ----------------------- |
| 🏠 Home        | ✅ Works         | ✅ Works            | ✅ Works                |
| 🏢 Office      | ❌ Not reachable | ✅ Works            | ✅ Works                |
| ☕ Coffee shop | ❌ Not reachable | ❌ Not reachable    | ✅ Works                |
| 📱 Mobile      | ❌ Not reachable | ❌ Not reachable    | ✅ Works                |

**Always use Tailscale when LAN doesn't work** - it works from everywhere.

### Connected Nodes

| Host              | Platform | Tailscale Address | Status    |
| ----------------- | -------- | ----------------- | --------- |
| **imac0**         | macOS    | imac0.ts.barta.cm | ✅ Active |
| **mba-imac-work** | macOS    | imacw.ts.barta.cm | ✅ Active |
| **mba-mbp-work**  | macOS    | mbpw.ts.barta.cm  | ✅ Active |
| **hsb0**          | NixOS    | hsb0.ts.barta.cm  | ✅ Active |
| **hsb1**          | NixOS    | hsb1.ts.barta.cm  | ✅ Active |
| **gpc0**          | NixOS    | gpc0.ts.barta.cm  | ✅ Active |
| **csb0**          | NixOS    | csb0.ts.barta.cm  | ✅ Active |
| **csb1**          | NixOS    | csb1.ts.barta.cm  | ✅ Active |
<!-- miniserver-bp moved to BYTEPOETS/bpnixcfg on 2026-05-02 (INSPR-24) -->


### Adding a New Node

**1. Generate a pre-auth key on csb0:**

```bash
# Long-lived reusable key (stored in 1Password!)
ssh mba@cs0.barta.cm -p 2222 \
  "docker exec headscale headscale preauthkeys create --user <username> --reusable --expiration 87600h"
```

> The user is baked into the key at creation time. No `--user` needed on the client.

**2. Connect the device:**

```bash
# macOS (use the .app CLI, NOT brew's tailscale)
/Applications/Tailscale.app/Contents/MacOS/Tailscale up --login-server https://hs.barta.cm --authkey <KEY>

# NixOS (requires services.tailscale.enable = true; deployed first)
sudo tailscale up --login-server https://hs.barta.cm --authkey <KEY>
```

**3. Verify:**

```bash
# On the new node
tailscale status

# On csb0 (list all nodes)
ssh mba@cs0.barta.cm -p 2222 "docker exec headscale headscale nodes list"
```

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

## 📡 Fleet Management

**NixFleet** has been decommissioned (DSC26-53). Its successor **FleetCom** (DSC26-52) is in development.

NixFleet previously provided centralized monitoring and push-button deployment via an agent-based pull model. All agents have been disabled across hosts. The NixFleet codebase remains at `~/Code/nixfleet` for reference.

---

## 🏠 Smart Home Naming Convention

Room codes, device types, and MQTT topic templates for all smart home devices.

### Room Codes

| Code | Room (EN)   | Room (DE)    |
| ---- | ----------- | ------------ |
| `bz` | bathroom    | Badezimmer   |
| `dt` | rooftop     | Dachterrasse |
| `ez` | diningroom  | Esszimmer    |
| `gb` | guestbath   | Gäste-Bad    |
| `gw` | guesttoilet | Gäste-WC     |
| `gz` | guestroom   | Gäste-Zimmer |
| `ke` | basement    | Keller       |
| `ki` | kidsroom    | Kinderzimmer |
| `ku` | kitchen     | Küche        |
| `sh` | hallway     | Stiegenhaus  |
| `sz` | bedroom     | Schlafzimmer |
| `te` | terrace     | Terrasse     |
| `tg` | parking     | Tiefgarage   |
| `vk` | backkitchen | Vorküche     |
| `vr` | foyer       | Vorraum      |
| `wc` | toilet      | WC           |
| `wz` | livingroom  | Wohnzimmer   |

### Special / Object Codes

| Code    | EN        | DE          |
| ------- | --------- | ----------- |
| `o-boi` | boiler    | Boiler      |
| `o-kus` | fridge    | Kühlschrank |
| `o-sra` | closet    | Schrank     |
| `smah`  | smarthome | Smarthome   |

### Device Type Codes

| Code       | HomeKit Type | Description          |
| ---------- | ------------ | -------------------- |
| `light`    | light        | Light                |
| `window`   | window       | Window               |
| `door`     | door         | Door                 |
| `blind`    | blind        | Blind                |
| `lock`     | lock         | Lock                 |
| `temp`     | sensor       | Temperature          |
| `humidity` | sensor       | Humidity             |
| `pressure` | sensor       | Pressure             |
| `contact`  | sensor       | Contact              |
| `motion`   | sensor       | Movement             |
| `camera`   | camera       | Camera               |
| `speaker`  | speaker      | Speaker              |
| `water`    | switch       | Water                |
| `tv`       | switch       | TV                   |
| `heating`  | heating      | Heating              |
| `co2`      | sensor       | Air Quality CO2      |
| `tvoc`     | sensor       | Air Quality TVOC     |
| `smoke`    | sensor       | Smoke Detector       |
| `alarm`    | alarm        | Security Alarm       |
| `fan`      | fan          | Fan                  |
| `switch`   | switch       | Switch               |
| `plug`     | plug         | Plug                 |
| `special`  | switch       | Generic Smart Device |

### MQTT Topic Templates

```
home/_room/_type/_entity          ← room-scoped devices
home/_room/door/_targetroom-d     ← door to another room
jhw2211/_category/_entity         ← home-wide / infra-level topics
```

**Examples:**

```
home/smarthome/switch/syncbox-sync
home/bz/light/d13
home/boiler/temp
home/vr/door/sh-d
home/wz/door/te-d
home/wz/button/pixoo01
home/ki/contact/w06
jhw2211/sensor/weatherStationAddon/vr/setTime
jhw2211/health/boiler
jhw2211/health/heat-chain
```

> `jhw2211` = home identity prefix (address/apartment code). Use for home-wide concerns not tied to a single room.
>
> Source of truth: Google Sheets: https://docs.google.com/spreadsheets/d/189WtwTyrDPWnu6OvpM3_8O-jQG9mq9Qt7ycR5p9zOK4/edit?gid=292639110#gid=292639110

---

## 🚨 Migration Notes (2026-01-10)

Modernized patterns for `csb0` transition:

- **Secrets**: Replaced local `.env` files with Agenix `/run/agenix/` secrets.
- **Data**: Moved bind mounts to persistent ZFS volumes at `/var/lib/docker/volumes/`.
- **Infrastructure**: Documented source configs for Traefik and Mosquitto from the legacy environment.
