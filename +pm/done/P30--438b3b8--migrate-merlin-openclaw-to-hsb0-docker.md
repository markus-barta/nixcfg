# Migrate Merlin (OpenClaw) from hsb1 Nix package to hsb0 Docker

**Host**: hsb0
**Priority**: P30
**Status**: In Progress (Phase 7 cleanup)
**Created**: 2026-02-13

---

## Problem

Merlin (OpenClaw AI assistant) runs on hsb1 as a **Nix package built from source**. This is:

- **Brittle**: `pnpm` monorepo build with native deps (`node-llama-cpp`, `cmake`, `python3`), platform-specific hashes, version patching hacks
- **High maintenance**: Every OpenClaw update requires rebuilding the Nix package, updating hashes, fixing build breakage
- **Fragile state**: Imperative config (`openclaw.json`, auth profiles, cron jobs, skill symlinks) -- skill symlinks break on Nix GC/updates
- **Known broken**: iCal sync (P40 backlog), skill symlinks pointing to GC'd store paths

Percy (miniserver-bp) runs OpenClaw in **Docker** via `npm install -g openclaw@latest` and is far more stable and easier to update. Merlin should follow the same pattern but on hsb0.

## Solution

Migrate Merlin to a **Docker container on hsb0**, replicating the proven miniserver-bp pattern (`virtualisation.oci-containers`). Transfer persistent state (config, workspace, skills, cron jobs) from hsb1. Stop (but don't delete) the hsb1 service so it doesn't interfere.

### Why hsb0?

- hsb1 (Mac mini 2014, 16GB) stays available for other workloads
- hsb0 (Mac mini 2011, 8GB, 223GB free SSD) has Docker already running, modest but sufficient for OpenClaw
- hsb0 is the DNS/DHCP crown jewel but OpenClaw is low-risk (container-isolated, `--network=host`)
- Home LAN, same network as hsb1 -- Home Assistant still reachable at `192.168.1.101:8123`

### Architecture comparison

| Aspect   | hsb1 (current)                      | hsb0 (target)                                                   |
| -------- | ----------------------------------- | --------------------------------------------------------------- |
| Runtime  | Nix package (pnpm from-source)      | Docker container (npm registry)                                 |
| Service  | `systemd.services.openclaw-gateway` | `virtualisation.oci-containers`                                 |
| Config   | Imperative (`~/.openclaw/`)         | Activation script seeds `openclaw.json`                         |
| Secrets  | env vars via wrapper script         | agenix → mounted files + activation script                      |
| Update   | Rebuild Nix package (hard)          | `docker build --no-cache` (easy)                                |
| Skills   | Imperative + broken symlinks        | Workspace volume (persistent)                                   |
| Calendar | vdirsyncer + khal (native)          | iCloud: vdirsyncer+khal in container; M365: Graph API read-only |

## Current Merlin State (hsb1)

### Secrets (6 total)

| Secret                          | Purpose                   | Migration                                                      |
| ------------------------------- | ------------------------- | -------------------------------------------------------------- |
| `hsb1-openclaw-gateway-token`   | Gateway WS auth           | Create new `hsb0-openclaw-*` secrets                           |
| `hsb1-openclaw-telegram-token`  | `@merlin_oc_bot` Telegram | **Reuse** -- same bot, new host                                |
| `hsb1-openclaw-openrouter-key`  | LLM inference             | **Reuse** -- same API key                                      |
| `hsb1-openclaw-hass-token`      | Home Assistant            | **Reuse** -- HASS at `192.168.1.101` still reachable from hsb0 |
| `hsb1-openclaw-brave-key`       | Web search                | **Reuse** -- same API key                                      |
| `hsb1-openclaw-icloud-password` | CalDAV sync (personal)    | **Reuse** -- iCloud calendar stays for personal use            |

### Persistent state to transfer

| What                | hsb1 path                                       | Transfer                   | Notes                                                    |
| ------------------- | ----------------------------------------------- | -------------------------- | -------------------------------------------------------- |
| `openclaw.json`     | `~/.openclaw/openclaw.json`                     | Copy + adapt               | Change workspace path, remove hardcoded tokens           |
| Agent auth profiles | `~/.openclaw/agents/main/agent/`                | Copy                       | OpenRouter auth profile, usage stats                     |
| Agent sessions      | `~/.openclaw/agents/main/sessions/`             | Copy                       | 21 session files (conversation history)                  |
| Workspace docs      | `~/.openclaw/workspace/*.md`                    | Copy                       | IDENTITY.md, USER.md, MEMORY.md, HEARTBEAT.md, etc.      |
| Workspace memory    | `~/.openclaw/workspace/memory/`                 | Copy                       | family.md, infrastructure.md, debug_log.md, workflows.md |
| Workspace skills    | `~/.openclaw/workspace/skills/`                 | **Selective**              | See skills section below                                 |
| Cron jobs           | `~/.openclaw/cron/jobs.json`                    | Copy                       | Currently empty (`"jobs": []`)                           |
| Credentials         | `~/.openclaw/credentials/`                      | Copy                       | telegram-allowFrom.json, telegram-pairing.json           |
| Exec approvals      | `~/.openclaw/exec-approvals.json`               | **Adapt**                  | Socket path needs updating for Docker                    |
| Canvas              | `~/.openclaw/canvas/`                           | Copy                       | If non-empty                                             |
| Identity/devices    | `~/.openclaw/identity/`, `~/.openclaw/devices/` | **Do NOT copy**            | New device identity will be generated on hsb0            |
| `m365_token.json`   | `~/.openclaw/m365_token.json`                   | **Do NOT copy**            | Stale token from deleted Merlin-AI-hsb1 app              |
| Telegram state      | `~/.openclaw/telegram/`                         | Copy                       | Preserves chat state                                     |
| vdirsyncer config   | `~/.config/vdirsyncer/config`                   | Copy into container volume | Needed for iCloud CalDAV                                 |
| khal config         | `~/.config/khal/config`                         | Copy into container volume | Needed for calendar display                              |

### Skills migration

| Skill                        | Type                 | Transfer | Notes                                                 |
| ---------------------------- | -------------------- | -------- | ----------------------------------------------------- |
| `calendar` (caldav-calendar) | Real workspace skill | **Copy** | vdirsyncer + khal, needs bins installed in Dockerfile |
| `openrouter-free-models`     | Real workspace skill | **Copy** | Includes `scripts/fetch_models.sh`                    |
| `docker`                     | **Broken symlink**   | **Skip** | Points to GC'd nix store path `openclaw-2026.1.29`    |
| `home-assistant`             | **Broken symlink**   | **Skip** | Points to GC'd nix store path `openclaw-2026.1.29`    |

The two broken symlinks (`docker`, `home-assistant`) point to `/nix/store/3k2mx0c9csz5l1wiazajg9b5xxif8r49-openclaw-2026.1.29/...` which no longer exists. In Docker, these bundled skills ship with `openclaw@latest` and will be available automatically -- no symlinks needed.

### Services/skills

| Service                     | How connected                                    | hsb0 impact                                                        |
| --------------------------- | ------------------------------------------------ | ------------------------------------------------------------------ |
| Telegram (`@merlin_oc_bot`) | Bot token env var                                | Same token, only one instance can poll -- **must stop hsb1 first** |
| OpenRouter (LLM)            | API key env var                                  | No change                                                          |
| Brave Search                | API key env var                                  | No change                                                          |
| Home Assistant              | HASS token, skill reads from `/run/agenix/` path | Mount secret in container, update skill config for new path        |
| iCloud Calendar (personal)  | vdirsyncer + khal (CalDAV)                       | Install in container, read/write personal calendar                 |
| M365 Calendar (company)     | Graph API via `m365 request`                     | Read-ONLY via separate Azure AD app (`Merlin-AI-hsb0-cal`)         |
| Cron/scheduler              | Built-in OpenClaw                                | Transfer `jobs.json`                                               |

## Implementation

### Phase 0: Preparation

**Calendar Architecture Decision (DONE - see below)**

**Document current Merlin `openclaw.json` settings (DONE - see Migration Notes below)**

**Migration Notes from hsb1 inspection:**

| Setting            | Current Value (hsb1)            | Docker Change Required                                               |
| ------------------ | ------------------------------- | -------------------------------------------------------------------- |
| **Workspace path** | `/home/mba/.openclaw/workspace` | Change to `/home/node/.openclaw/workspace` (Docker uses `node` user) |
| **Bot token**      | Hardcoded in JSON               | Move to agenix secret, inject via activation script                  |
| **Gateway token**  | Hardcoded in JSON               | Move to agenix secret, inject via activation script                  |
| **User context**   | `mba`                           | `node` (uid 1000 inside container)                                   |

**Settings that copy AS-IS (no changes needed):**

- **Models**: Primary `openrouter/google/gemini-3-flash-preview`, Fallback `openrouter/moonshotai/kimi-k2.5`
- **Tools**: Web search/fetch enabled
- **Channels**: Telegram enabled, dmPolicy=pairing, streamMode=partial
- **Gateway**: Port 18789, bind=lan, allowInsecureAuth=true
- **Cron**: Enabled
- **Skills**: nodeManager=npm
- **Max concurrent**: 4 agents / 8 subagents

**Files to transfer from hsb1:**

```bash
# TRANSFER (copy to /var/lib/openclaw-merlin/data/ on hsb0):
~/.openclaw/openclaw.json          # Adapt: paths, remove hardcoded tokens
~/.openclaw/agents/main/           # Auth profiles, sessions (21 files)
~/.openclaw/workspace/*.md         # IDENTITY, USER, MEMORY, HEARTBEAT, SOUL, TOOLS
~/.openclaw/workspace/memory/      # family.md, infrastructure.md, debug_log.md, workflows.md
~/.openclaw/workspace/skills/calendar/          # CalDAV skill (real dir)
~/.openclaw/workspace/skills/openrouter-free-models/  # Model finder skill (real dir)
~/.openclaw/cron/                  # jobs.json (currently empty)
~/.openclaw/credentials/           # telegram-allowFrom.json, telegram-pairing.json
~/.openclaw/exec-approvals.json    # Adapt: socket path for Docker
~/.openclaw/canvas/                # If non-empty
~/.openclaw/telegram/              # Chat state

# ALSO TRANSFER (calendar configs, mount separately in container):
~/.config/vdirsyncer/config        # iCloud CalDAV
~/.config/khal/config              # Calendar display

# DO NOT TRANSFER:
~/.openclaw/identity/              # New device identity generated on hsb0
~/.openclaw/devices/               # New device registration on hsb0
~/.openclaw/m365_token.json        # Stale (Merlin-AI-hsb1 app deleted)
~/.openclaw/workspace/skills/docker            # Broken symlink to GC'd nix store
~/.openclaw/workspace/skills/home-assistant    # Broken symlink to GC'd nix store
```

**Verify hsb0 resources (DONE - see Capacity Assessment below)**

**Capacity Assessment from research:**

| Resource   | hsb0 Spec                | Current Usage               | OpenClaw Need                   | Verdict       |
| ---------- | ------------------------ | --------------------------- | ------------------------------- | ------------- |
| **CPU**    | i5-2415M 2.3GHz (2C/4T)  | Light (DNS, monitoring)     | Low (API calls, occasional LLM) | ✅ Sufficient |
| **RAM**    | 8 GB DDR3                | ~2-3 GB used                | ~1-2 GB for OpenClaw            | ✅ Sufficient |
| **Disk**   | 250 GB SSD (223 GB free) | ~9 GB used                  | ~1 GB for container + state     | ✅ Plenty     |
| **Docker** | Already enabled          | 2 containers (restic, ncps) | Add 1 container                 | ✅ Ready      |

**Current hsb0 containers:**

- `restic-cron-hetzner` (backup, minimal resources)
- `ncps` (Nix cache proxy, port 8501)

**OpenClaw resource profile:**

- Mostly idle (waits for Telegram messages)
- Spikes during LLM inference (OpenRouter API, not local)
- Minimal disk I/O (logs, workspace files)
- Network: Port 18789 needs firewall opening

**Pre-migration verification needed on hsb0:**

```bash
# Run these on hsb0 before starting:
free -h                    # Confirm >4GB available
df -h /var/lib/docker      # Confirm >10GB free
docker ps                  # Verify existing containers running
docker info | grep -i "storage"  # Confirm overlay2 or zfs driver
```

---

### Calendar Architecture (Approved)

Merlin is **strictly a personal AI for private use**. Company data access is **read-only** only.

| Calendar             | Service       | Access Level  | Implementation                                              |
| -------------------- | ------------- | ------------- | ----------------------------------------------------------- |
| **Personal/Private** | iCloud        | Read/Write    | vdirsyncer + khal (CalDAV) inside container                 |
| **Company**          | Microsoft 365 | **Read-ONLY** | Separate Azure AD app with `Calendars.Read` permission only |

**Company Access Details:**

- **Azure AD App**: `Merlin-AI-hsb0-cal` (separate from Percy's email app)
- **Permissions**: `Calendars.Read` only (NOT `Calendars.ReadWrite`)
- **Scope**: Can read `markus.barta@bytepoets.com` calendar events
- **NO email access**: Merlin does NOT have `Mail.Read` or `Mail.Send` for company account
- **Write operations**: If company calendar/email write needed, Merlin uses **inter-agent communication** to ask Percy (who has company email permissions)

**Why separate Azure AD app for calendar?**

- Clean security boundary: calendar-only, read-only
- Different scope from Percy's email app (`Mail.Read`, `Mail.Send`)
- Enforced at Azure level (can't accidentally write to company calendar)
- Follows principle of least privilege

**Graph API Commands for Company Calendar:**

```bash
# List events for next 7 days
m365 request --url "https://graph.microsoft.com/v1.0/users/markus.barta@bytepoets.com/calendar/calendarView?startDateTime=2026-02-13T00:00:00Z&endDateTime=2026-02-20T23:59:59Z" --method get

# List all calendars
m365 request --url "https://graph.microsoft.com/v1.0/users/markus.barta@bytepoets.com/calendars" --method get
```

### Phase 1: Dockerfile + NixOS config on hsb0

- [ ] Create `hosts/hsb0/docker/openclaw-merlin/Dockerfile` (based on miniserver-bp pattern)
  - `node:22-bookworm-slim`
  - `openclaw@latest`
  - `@pnp/cli-microsoft365` (for company calendar read-only via Graph API)
  - `vdirsyncer` + `khal` (apt: for iCloud CalDAV personal calendar)
  - `git` + `curl` (required by OpenClaw)
  - NO `gogcli` (Merlin doesn't use Google Workspace)
- [ ] Add `virtualisation.oci-containers` definition to `hosts/hsb0/configuration.nix`
  - Container: `openclaw-merlin`
  - `--network=host`
  - Port: `18789`
  - Volume: `/var/lib/openclaw-merlin/data:/home/node/.openclaw:rw`
  - agenix secrets mounted read-only
- [ ] Create agenix secrets for hsb0:
  - `hsb0-openclaw-gateway-token.age` (new token)
  - `hsb0-openclaw-telegram-token.age` (copy from hsb1)
  - `hsb0-openclaw-openrouter-key.age` (copy from hsb1)
  - `hsb0-openclaw-hass-token.age` (copy from hsb1)
  - `hsb0-openclaw-brave-key.age` (copy from hsb1)
  - `hsb0-openclaw-icloud-password.age` (for iCloud CalDAV)
  - `hsb0-openclaw-m365-cal-client-id.age` (Azure AD app `Merlin-AI-hsb0-cal`)
  - `hsb0-openclaw-m365-cal-tenant-id.age` (same tenant as Percy)
  - `hsb0-openclaw-m365-cal-client-secret.age` (read-only calendar app)
- [ ] Add secrets to `secrets/secrets.nix` with hsb0 host key
- [ ] Add activation script to seed `openclaw.json` with Telegram token
- [ ] Open port 18789 in hsb0 firewall

### Phase 2: Transfer state from hsb1

- [ ] Stop Merlin on hsb1: `sudo systemctl stop openclaw-gateway && sudo systemctl mask openclaw-gateway`
- [ ] Copy persistent state from hsb1 to hsb0:

  ```bash
  # On hsb0:
  sudo mkdir -p /var/lib/openclaw-merlin/data
  sudo mkdir -p /var/lib/openclaw-merlin/vdirsyncer
  sudo mkdir -p /var/lib/openclaw-merlin/khal

  # Transfer OpenClaw state (selective -- see transfer list above):
  scp mba@hsb1.lan:~/.openclaw/openclaw.json /tmp/openclaw.json
  scp -r mba@hsb1.lan:~/.openclaw/agents /tmp/agents
  scp -r mba@hsb1.lan:~/.openclaw/cron /tmp/cron
  scp -r mba@hsb1.lan:~/.openclaw/credentials /tmp/credentials
  scp -r mba@hsb1.lan:~/.openclaw/canvas /tmp/canvas 2>/dev/null
  scp -r mba@hsb1.lan:~/.openclaw/telegram /tmp/telegram
  scp mba@hsb1.lan:~/.openclaw/exec-approvals.json /tmp/exec-approvals.json

  # Transfer workspace (skip broken symlinks):
  scp -r mba@hsb1.lan:~/.openclaw/workspace/*.md /tmp/workspace/
  scp -r mba@hsb1.lan:~/.openclaw/workspace/memory /tmp/workspace/memory
  scp -r mba@hsb1.lan:~/.openclaw/workspace/skills/calendar /tmp/workspace/skills/calendar
  scp -r mba@hsb1.lan:~/.openclaw/workspace/skills/openrouter-free-models /tmp/workspace/skills/openrouter-free-models

  # Transfer calendar configs:
  scp mba@hsb1.lan:~/.config/vdirsyncer/config /tmp/vdirsyncer-config
  scp mba@hsb1.lan:~/.config/khal/config /tmp/khal-config

  # Assemble on hsb0:
  sudo cp -r /tmp/{openclaw.json,agents,cron,credentials,canvas,telegram,exec-approvals.json} /var/lib/openclaw-merlin/data/
  sudo mkdir -p /var/lib/openclaw-merlin/data/workspace/{skills,memory}
  sudo cp -r /tmp/workspace/* /var/lib/openclaw-merlin/data/workspace/
  sudo cp /tmp/vdirsyncer-config /var/lib/openclaw-merlin/vdirsyncer/config
  sudo cp /tmp/khal-config /var/lib/openclaw-merlin/khal/config
  sudo chown -R 1000:1000 /var/lib/openclaw-merlin/
  ```

- [ ] Adapt `openclaw.json`:
  - Change workspace path: `/home/mba/.openclaw/workspace` → `/home/node/.openclaw/workspace`
  - Remove hardcoded `botToken` (injected via activation script)
  - Remove hardcoded `gateway.auth.token` (injected via activation script)
  - Verify `bind=lan`, `allowInsecureAuth=true`, `port=18789` (should be correct as-is)
- [ ] Adapt `exec-approvals.json`:
  - Change socket path: `/home/mba/.openclaw/` → `/home/node/.openclaw/`
- [ ] Login M365 CLI for company calendar (after container starts):
  ```bash
  docker exec -it openclaw-merlin sh -c \
    'm365 login --authType secret \
      --appId "$(cat /run/secrets/m365-cal-client-id)" \
      --tenant "$(cat /run/secrets/m365-cal-tenant-id)" \
      --secret "$(cat /run/secrets/m365-cal-client-secret)"'
  ```

### Phase 3: Build + Deploy on hsb0

- [ ] Commit + push
- [ ] Pull on hsb0: `cd ~/Code/nixcfg && git pull`
- [ ] Build Docker image: `cd hosts/hsb0/docker/openclaw-merlin && docker build -t openclaw-merlin:latest .`
- [ ] NixOS rebuild: `sudo nixos-rebuild switch --flake .#hsb0`
- [ ] **Important**: Mask service first for onboard wizard if fresh config:
  ```bash
  sudo systemctl mask docker-openclaw-merlin
  # Run onboard if needed, then unmask
  sudo systemctl unmask docker-openclaw-merlin
  sudo systemctl start docker-openclaw-merlin
  ```

### Phase 4: Verify + Test

- [ ] Verify gateway starts: `docker logs openclaw-merlin`
- [ ] Check status: `curl http://192.168.1.99:18789/health`
- [ ] Test Telegram: send message to `@merlin_oc_bot` -- should respond from hsb0 now
- [ ] Test Home Assistant: ask Merlin to check lights/sensors
- [ ] Test Brave Search: ask Merlin to search the web
- [ ] Test cron: verify scheduled tasks run
- [ ] Test calendar (if applicable)
- [ ] Verify memory/context carried over from hsb1

### Phase 5: Decommission hsb1 OpenClaw

- [ ] Disable (don't delete) hsb1 service:
  ```nix
  # In hsb1/configuration.nix:
  systemd.services.openclaw-gateway.enable = false;
  ```
  Or simpler: mask the service
- [ ] Keep hsb1 secrets in repo (don't delete -- rollback safety)
- [ ] Keep hsb1 `openclaw` package in config but remove from `wantedBy` (so it's available but not running)
- [ ] **Do NOT delete** hsb1 state (`~/.openclaw/`) -- keep as backup for 30 days minimum
- [ ] Remove `vdirsyncer` and `khal` from hsb1 packages if no longer needed

### Phase 6: Cleanup + Docs

- [ ] Update hsb0 README.md (add OpenClaw/Merlin to services)
- [ ] Update hsb0 RUNBOOK.md (add OpenClaw operational commands)
- [ ] Create `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md` (based on miniserver-bp template)
- [ ] Update hsb1 README.md (note Merlin migrated to hsb0)
- [ ] Update hsb1 RUNBOOK.md (note service disabled, state preserved)
- [ ] Update `docs/INFRASTRUCTURE.md` (Merlin now on hsb0)
- [ ] Consider: close/update related backlog items:
  - `P94--0e9a020--openclaw-deployment.md` (hsb1) -- superseded
  - `P66--56fe6e8--declarative-openclaw-skills.md` (hsb1) -- Docker makes this moot
  - `P40--0c5e66c--ical-sync-fix.md` (hsb1) -- migrated or replaced
  - `P66--5c3930e--declarative-openclaw-gateway.md` (infra) -- Docker approach instead
  - `P40--0dd6291--openclaw-update-automation.md` (infra) -- Docker `--no-cache` rebuild is trivial

### Phase 7: hsb1 Cleanup (post-migration, 2026-02-14)

Migration successful. Now remove all hsb1 OpenClaw infrastructure from the repo.
Each item below lists the exact change, git-revertable via `git log --all --oneline -- <file>`.

> **iCal sync (P40) stays open** -- still needed on hsb0 Docker. Moved from hsb1 backlog to hsb0 backlog.

#### 7a. `hosts/hsb1/configuration.nix` -- remove all OpenClaw blocks

| What                                                                       | Lines (approx) | Action                                       |
| -------------------------------------------------------------------------- | -------------- | -------------------------------------------- |
| `let openclaw = pkgs.callPackage ../../pkgs/openclaw/package.nix {};`      | 9-10           | **Delete** let binding                       |
| `services.cron.enable = true;` + comment "(needed for OpenClaw scheduler)" | 63             | **Delete** if nothing else uses cron on hsb1 |
| `OPENCLAW_TEMPLATES_DIR` env var                                           | 224-225        | **Delete** from `environment.variables`      |
| `openclaw` in `environment.systemPackages`                                 | 256            | **Delete** package                           |
| `vdirsyncer` in `environment.systemPackages`                               | 257            | **Delete** (calendar now in Docker on hsb0)  |
| `khal` in `environment.systemPackages`                                     | 258            | **Delete** (calendar now in Docker on hsb0)  |
| 6x `age.secrets.hsb1-openclaw-*` blocks                                    | 506-543        | **Delete** all 6 secret declarations         |
| `systemd.services.openclaw-gateway` block (disabled)                       | 562-614        | **Delete** entire block incl. comment header |

**Rollback**: `git show HEAD:hosts/hsb1/configuration.nix` to see previous state.

#### 7b. `secrets/secrets.nix` -- remove hsb1 secret entries

| What                                   | Lines (approx) | Action     |
| -------------------------------------- | -------------- | ---------- |
| Comment block "OpenClaw Merlin (hsb1)" | 153-157        | **Delete** |
| `hsb1-openclaw-gateway-token.age`      | 158            | **Delete** |
| `hsb1-openclaw-telegram-token.age`     | 159            | **Delete** |
| `hsb1-openclaw-openrouter-key.age`     | 160            | **Delete** |
| `hsb1-openclaw-hass-token.age`         | 161            | **Delete** |
| `hsb1-openclaw-brave-key.age`          | 162            | **Delete** |
| `hsb1-openclaw-icloud-password.age`    | 163            | **Delete** |

**Rollback**: Entries can be re-added; .age files still in git history.

#### 7c. `secrets/*.age` -- delete 6 encrypted files

| File                                        | Action     |
| ------------------------------------------- | ---------- |
| `secrets/hsb1-openclaw-gateway-token.age`   | **Delete** |
| `secrets/hsb1-openclaw-telegram-token.age`  | **Delete** |
| `secrets/hsb1-openclaw-openrouter-key.age`  | **Delete** |
| `secrets/hsb1-openclaw-hass-token.age`      | **Delete** |
| `secrets/hsb1-openclaw-brave-key.age`       | **Delete** |
| `secrets/hsb1-openclaw-icloud-password.age` | **Delete** |

**Rollback**: `git checkout <commit>^ -- secrets/hsb1-openclaw-*.age` to restore.
Note: These are encrypted -- content not lost, just needs re-encryption if restored.

#### 7d. `pkgs/openclaw/` -- delete entire package directory

| File                                    | Action     |
| --------------------------------------- | ---------- |
| `pkgs/openclaw/package.nix` (135 lines) | **Delete** |
| `pkgs/openclaw/justfile`                | **Delete** |

**Rollback**: `git checkout <commit>^ -- pkgs/openclaw/` to restore.
Note: Package was only used by hsb1. hsb0 uses Docker (`npm install -g openclaw@latest`).

#### 7e. `scripts/update-openclaw.sh` -- delete update script

| File                                     | Action     |
| ---------------------------------------- | ---------- |
| `scripts/update-openclaw.sh` (180 lines) | **Delete** |

**Rollback**: `git checkout <commit>^ -- scripts/update-openclaw.sh`.
Note: Script was hsb1-only; Docker updates via `docker build --no-cache`.

#### 7f. `justfile` -- remove openclaw recipes

| What                           | Lines (approx) | Action     |
| ------------------------------ | -------------- | ---------- |
| `update-openclaw` recipe       | 577-580        | **Delete** |
| `update-openclaw-force` recipe | 582-585        | **Delete** |

**Rollback**: `git show <commit>^:justfile` to see previous state.

#### 7g. `flake.nix` -- remove openclaw comments

| What                                             | Lines (approx) | Action     |
| ------------------------------------------------ | -------------- | ---------- |
| Comment about openclaw package in overlays-local | 68-69          | **Delete** |

#### 7h. `hosts/hsb1/docs/RUNBOOK.md` -- trim OpenClaw section

| What                                          | Lines (approx) | Action                                                     |
| --------------------------------------------- | -------------- | ---------------------------------------------------------- |
| Full "OpenClaw AI Assistant (Merlin)" section | 543-648        | **Replace** with short "Migrated to hsb0" note (3-5 lines) |
| OpenClaw in web interfaces table              | 356            | **Remove** row                                             |

**Rollback**: `git show <commit>^:hosts/hsb1/docs/RUNBOOK.md`.

#### 7i. Backlog items -- delete superseded, move ical-sync

| File                                                                     | Action                                 | Reason                                 |
| ------------------------------------------------------------------------ | -------------------------------------- | -------------------------------------- |
| `hosts/hsb1/docs/backlog/P94--0e9a020--openclaw-deployment.md`           | **Delete**                             | Superseded by Docker migration         |
| `hosts/hsb1/docs/backlog/P66--56fe6e8--declarative-openclaw-skills.md`   | **Delete**                             | Docker makes skill symlinks moot       |
| `hosts/hsb1/docs/backlog/P40--0c5e66c--ical-sync-fix.md`                 | **Move** to `hosts/hsb0/docs/backlog/` | Still needed -- fix on hsb0 Docker now |
| `+pm/backlog/infra/P66--5c3930e--declarative-openclaw-gateway.md`        | **Delete**                             | Replaced by Docker approach            |
| `+pm/backlog/infra/P40--0dd6291--openclaw-update-automation.md`          | **Delete**                             | Docker `--no-cache` is trivial         |
| `+pm/backlog/infra/P45--3f8672e--generic-home-assistant-skill.md`        | **Update**                             | Change host ref from hsb1 → hsb0       |
| `+pm/backlog/infra/P21--7537467--fix-cron-scheduling-sync.md`            | **Update**                             | Change host ref from hsb1 → hsb0       |
| `+pm/backlog/infra/P22--2a75158--fix-gemini-thought-signature-errors.md` | **Keep**                               | Not hsb1-specific                      |
| `+pm/pickups/P9400-pickup-2026-01-31.md`                                 | **Delete**                             | Historical hsb1 deployment session     |

**Rollback**: All files recoverable from git history.

#### 7j. On-host cleanup (manual, on hsb1 via SSH)

> These are **runtime artifacts**, NOT in git. Do after 30 days or when confident.

| What                   | Path on hsb1               | Action                                                          |
| ---------------------- | -------------------------- | --------------------------------------------------------------- |
| OpenClaw state dir     | `~/.openclaw/`             | **Keep 30 days**, then delete                                   |
| vdirsyncer config      | `~/.config/vdirsyncer/`    | **Delete** (now in hsb0 Docker volume)                          |
| khal config            | `~/.config/khal/`          | **Delete** (now in hsb0 Docker volume)                          |
| Masked systemd service | `openclaw-gateway.service` | Auto-removed when config block deleted + `nixos-rebuild switch` |

---

## Acceptance Criteria

- [x] Merlin responds via Telegram (`@merlin_oc_bot`) from hsb0
- [x] Home Assistant integration works (lights, sensors)
- [x] Brave Search works
- [x] Cron/scheduled tasks execute
- [ ] iCloud personal calendar works (vdirsyncer sync + khal query) -- **P40 still open**
- [ ] M365 company calendar works (read-only via Graph API) -- **Azure AD app not yet created**
- [x] Memory/context preserved from hsb1
- [x] hsb1 OpenClaw service stopped and disabled
- [ ] hsb1 infrastructure fully removed from repo (Phase 7)
- [x] All docs updated (hsb0 RUNBOOK, hsb1 RUNBOOK, INFRASTRUCTURE.md)
- [ ] `docker build --no-cache` successfully updates OpenClaw (test upgrade path)

## Risks

| Risk                                       | Impact                           | Mitigation                                                                                       |
| ------------------------------------------ | -------------------------------- | ------------------------------------------------------------------------------------------------ |
| hsb0 resource constraint (8GB RAM, 2C CPU) | Merlin slow or OOM               | Monitor with `docker stats`; OpenClaw is mostly API calls, low local compute                     |
| Telegram bot token conflict                | Two instances polling = errors   | **Stop hsb1 BEFORE starting hsb0** -- only one instance per bot token                            |
| HASS token path change                     | Home Assistant skill breaks      | Mount secret at known path in container; HA bundled skill reads from env or file -- verify which |
| State transfer incomplete                  | Lost memory/context              | Verify file list before decommissioning hsb1; keep hsb1 backup 30 days                           |
| iCloud CalDAV in container                 | Complex setup                    | Install vdirsyncer+khal via apt in Dockerfile; mount configs from host volume                    |
| hsb0 is crown jewel (DNS/DHCP)             | Container issue could affect DNS | OpenClaw is isolated in container; `--network=host` risk is low                                  |

## Key Gotchas (from miniserver-bp experience)

1. **`--network=host` is REQUIRED** -- Docker bridge causes "pairing required" errors
2. **`bind=lan`** in `openclaw.json` -- keeps Control UI accessible from LAN
3. **Run as `node` user** (uid 1000) -- otherwise `$HOME` mismatch breaks volume mounts
4. **`git` required** in Docker image for npm install
5. **Onboard wizard must run BEFORE gateway starts** -- gateway spins at 99% CPU without config
6. **Mask systemd service** during initial setup / onboard wizard
7. **`allowInsecureAuth: true`** needed for HTTP Control UI access (no HTTPS on LAN)
8. **Nix package approach is NOT recommended** -- Docker is more practical (lesson learned from hsb1)

## References

- miniserver-bp Docker setup (template): `hosts/miniserver-bp/docs/OPENCLAW-DOCKER-SETUP.md`
- miniserver-bp runbook (template): `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md`
- hsb1 current config: `hosts/hsb1/configuration.nix` (lines 506-611)
- hsb1 runbook: `hosts/hsb1/docs/RUNBOOK.md` (lines 543-646)
- Nix package (to be deprecated): `pkgs/openclaw/package.nix`
- OpenClaw docs: https://docs.openclaw.ai
- Related backlog: P66--5c3930e (declarative gateway), P45--3f8672e (HA skill), P48--025353e (cache)
