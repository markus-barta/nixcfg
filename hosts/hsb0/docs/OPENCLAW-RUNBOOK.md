# OpenClaw Runbook - hsb0

**Host**: hsb0 (192.168.1.99)
**Instance**: Merlin
**Port**: 18789
**Management**: docker-compose
**Version**: latest (npm)
**Updated**: 2026-02-15

---

## Architecture

**Management**: docker-compose

```
docker-compose.yml → Docker → node:22-bookworm-slim + openclaw@latest
                                ↓
                       /home/node/.openclaw (volume mount)
                                ↓
                       /var/lib/openclaw-merlin/data (host)
```

- Docker Compose manages container lifecycle
- Image built from `docker/openclaw-merlin/Dockerfile`
- Config + data persisted at `/var/lib/openclaw-merlin/data/`
- Secrets injected via env vars from agenix-mounted files (no plaintext in openclaw.json)
- NixOS activation script seeds dirs + openclaw.json template on first boot

### Secret Handling (2026-02-15 update)

All secrets now use env var substitution pattern:

1. **Agenix** decrypts secrets to `/run/agenix/hsb0-openclaw-*`
2. **Compose** mounts secrets as ro volumes to `/run/secrets/*`
3. **Entrypoint** reads secrets into env vars (`TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, `OPENROUTER_API_KEY`, `BRAVE_API_KEY`)
4. **openclaw.json** references via `${ENV_VAR}` (no plaintext tokens)

---

## Current Status

| Component       | Status        | Notes                            |
| --------------- | ------------- | -------------------------------- |
| Container       | ✅ Running    | Docker, `--network=host`         |
| Telegram        | ✅ Connected  | @merlin_oc_bot                   |
| Home Assistant  | ✅ Working    | HASS at 192.168.1.101:8123       |
| Brave Search    | ✅ Working    | Web search skill                 |
| Cron            | ✅ Working    | Built-in scheduler               |
| iCloud Calendar | ❌ Broken     | P40 -- vdirsyncer sync needs fix |
| M365 Calendar   | ❌ Not setup  | Azure AD app not yet created     |
| Opus Gateway    | ✅ Configured | Credentials mounted from agenix  |

## Available Skills

### Workspace Skills (user-installed)

| Skill                  | Description                             | Location                                   |
| ---------------------- | --------------------------------------- | ------------------------------------------ |
| calendar               | CalDAV sync (iCloud, vdirsyncer + khal) | `workspace/skills/calendar/`               |
| home-assistant         | Control Home Assistant (192.168.1.101)  | `workspace/skills/home-assistant/`         |
| opus-gateway           | EnOcean devices via Opus Gateway        | `workspace/skills/opus-gateway/`           |
| openrouter-free-models | Find free LLMs on OpenRouter            | `workspace/skills/openrouter-free-models/` |

All skills are home LAN specific except `openrouter-free-models` (portable).

```bash
# List all skills
docker exec openclaw-merlin openclaw skills list
```

## Operational Commands

### Check Status

```bash
# Container status (via docker compose)
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose ps

# Or via docker directly
docker ps | grep openclaw

# View logs
docker compose logs -f openclaw-merlin
# Or: docker logs -f openclaw-merlin

# Gateway health
curl http://192.168.1.99:18789/health
```

### Restart

```bash
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose restart openclaw-merlin
```

### Standard Deploy (after pushing changes to nixcfg)

```bash
# One-liner Markus uses on hsb0 directly:
gitpl && just switch && just merlin-rebuild
# gitpl = git pull + submodule update (fish alias)
# just switch = sudo nixos-rebuild switch --flake .#hsb0
# just merlin-rebuild = docker compose up -d --build --force-recreate openclaw-merlin
```

### Force Recreate (fresh boot)

```bash
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose up -d --force-recreate openclaw-merlin

# With rebuild:
docker compose build --no-cache openclaw-merlin
docker compose up -d --force-recreate openclaw-merlin
```

### Stop

```bash
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose stop openclaw-merlin
# Later: docker compose start openclaw-merlin
```

### View Config

```bash
# Current config
cat /var/lib/openclaw-merlin/data/openclaw.json | jq

# Gateway token
docker exec openclaw-merlin openclaw dashboard --no-open
```

### Edit Config

```bash
sudo vim /var/lib/openclaw-merlin/data/openclaw.json
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose restart openclaw-merlin
```

### Update OpenClaw

```bash
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose build --no-cache openclaw-merlin
docker compose up -d openclaw-merlin
```

## Telegram Operations

### Pairing

```bash
# List pending pairings
docker exec -it openclaw-merlin openclaw pairing list telegram

# Approve pairing
docker exec -it openclaw-merlin openclaw pairing approve telegram <CODE>
```

### Check Channel Status

```bash
docker exec openclaw-merlin openclaw channels list
```

## Home Assistant

Token mounted at `/run/secrets/hass-token` inside the container (from `/run/agenix/hsb0-openclaw-hass-token` on host).

```bash
# Test HA connectivity from inside container
docker exec openclaw-merlin sh -c \
  'curl -s -H "Authorization: Bearer $(cat /run/secrets/hass-token)" \
   http://192.168.1.101:8123/api/states | jq length'
```

## Opus Gateway

Credentials for the home's Opus gateway are mounted from agenix:

- Host: `/run/agenix/hsb0-openclaw-opus-gateway`
- Container: `/home/node/.openclaw/credentials/opus-gateway.env`
- Format: `.env` file (KEY=VALUE lines)

## Secrets (Agenix)

| Secret                          | Purpose                              | Container path                                      |
| ------------------------------- | ------------------------------------ | --------------------------------------------------- |
| `hsb0-openclaw-gateway-token`   | Gateway WS auth                      | Seeded into `openclaw.json` at activation           |
| `hsb0-openclaw-telegram-token`  | Telegram bot                         | Seeded into `openclaw.json` at activation           |
| `hsb0-openclaw-openrouter-key`  | LLM inference (OpenRouter)           | `/run/secrets/openrouter-key`                       |
| `hsb0-openclaw-hass-token`      | Home Assistant LLAT                  | `/run/secrets/hass-token`                           |
| `hsb0-openclaw-brave-key`       | Brave Search API                     | `/run/secrets/brave-key`                            |
| `hsb0-openclaw-icloud-password` | iCloud CalDAV (personal calendar)    | Not yet mounted (P40 pending)                       |
| `hsb0-openclaw-opus-gateway`    | Opus home gateway credentials        | `/home/node/.openclaw/credentials/opus-gateway.env` |
| `hsb0-openclaw-m365-cal-*`      | Microsoft Graph (read-only calendar) | Not yet created (Azure AD app pending)              |

All secrets are `mode = "444"` in NixOS config for Docker read access.

## Files Reference

| What                    | Location                                               |
| ----------------------- | ------------------------------------------------------ |
| Dockerfile              | `hosts/hsb0/docker/openclaw-merlin/Dockerfile`         |
| docker-compose          | `hosts/hsb0/docker/docker-compose.yml`                 |
| NixOS config            | `hosts/hsb0/configuration.nix`                         |
| Config (host)           | `/var/lib/openclaw-merlin/data/openclaw.json`          |
| Workspace               | `/var/lib/openclaw-merlin/data/workspace/`             |
| Credentials             | `/var/lib/openclaw-merlin/data/credentials/`           |
| vdirsyncer config       | `/var/lib/openclaw-merlin/vdirsyncer/config`           |
| khal config             | `/var/lib/openclaw-merlin/khal/config`                 |
| Device identity         | `/var/lib/openclaw-merlin/data/identity/device.json`   |
| Paired devices          | `/var/lib/openclaw-merlin/data/devices/paired.json`    |
| Container logs          | `docker logs openclaw-merlin`                          |
| Gateway log             | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (in container) |
| Secrets (agenix, NixOS) | `secrets/hsb0-openclaw-*.age`                          |

## Access

| Service    | URL                        |
| ---------- | -------------------------- |
| Control UI | http://192.168.1.99:18789/ |
| Telegram   | @merlin_oc_bot             |

---

## Troubleshooting

### "pairing required" -- cron/tools fail after fresh deploy or container rebuild

**Symptom**:

```
[tools] cron failed: gateway closed (1008): pairing required
Gateway target: ws://192.168.1.99:18789
```

**Root cause**: The gateway's internal agent client needs to be registered as a paired device. On a fresh deploy or if `devices/paired.json` is empty/missing, the agent shows up in `devices/pending.json` but is never auto-approved. The CLI can't approve it either (chicken-and-egg: CLI itself needs gateway access).

**Diagnosis**:

```bash
# Check paired devices (should NOT be empty)
docker exec openclaw-merlin cat /home/node/.openclaw/devices/paired.json

# Check pending devices (if agent is stuck here, that's the problem)
docker exec openclaw-merlin cat /home/node/.openclaw/devices/pending.json
```

**Fix**: Copy the pending device entry into `paired.json` manually. Get the `deviceId` and `publicKey` from `pending.json`, then write:

```bash
# 1. Read the pending device
docker exec openclaw-merlin cat /home/node/.openclaw/devices/pending.json | jq

# 2. Extract deviceId and publicKey, then write paired.json
# (replace DEVICE_ID and PUBLIC_KEY with actual values from step 1)
docker exec openclaw-merlin sh -c 'echo "{\"DEVICE_ID\":{\"deviceId\":\"DEVICE_ID\",\"publicKey\":\"PUBLIC_KEY\",\"displayName\":\"agent\",\"platform\":\"linux\",\"clientId\":\"gateway-client\",\"clientMode\":\"backend\",\"role\":\"operator\",\"roles\":[\"operator\"],\"scopes\":[\"operator.admin\",\"operator.approvals\",\"operator.pairing\"],\"approvedAt\":$(date +%s)000}}" > /home/node/.openclaw/devices/paired.json'

# 3. Restart container
docker restart openclaw-merlin
```

**Prevention**: After migration or fresh deploy, always check that `paired.json` is not empty. The migration plan intentionally skips `devices/` (new identity per host), so this step is always needed on first boot.

**See also**: Percy hit the same issue with Docker bridge networking. On Percy, `--network=host` fixed the in-process agent path (cron, Telegram). Merlin already uses `--network=host` but still needed manual device pairing on first boot. See [Percy investigation log](../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md#investigation-log-docker-bridge-vs-loopback).

### "All models failed / Provider in cooldown"

**Symptom**: `FailoverError: 403 Key limit exceeded (monthly limit)` or `Provider openrouter is in cooldown`.

**Root cause**: OpenRouter monthly billing limit hit, or stale API key cached in `auth-profiles.json`.

**Diagnosis**:

```bash
# Check auth profiles for stale keys or cooldown state
docker exec openclaw-merlin cat /home/node/.openclaw/agents/main/agent/auth-profiles.json | jq

# Verify the agenix key works:
curl -s https://openrouter.ai/api/v1/auth/key \
  -H "Authorization: Bearer $(cat /run/agenix/hsb0-openclaw-openrouter-key)"
```

**Fix**:

```bash
# Edit auth-profiles.json inside container:
# 1. Remove "key" field from profiles (let env var take over)
# 2. Remove "disabledUntil" and "disabledReason" from usageStats
# 3. Reset "errorCount" to 0 and "failureCounts" to {}
docker exec -it openclaw-merlin vi /home/node/.openclaw/agents/main/agent/auth-profiles.json

# Then restart
docker restart openclaw-merlin
```

### "schedule.at is in the past"

**Symptom**: `cron.add` fails with `schedule.at is in the past: ... (N minutes ago)`.

**Cause**: A cron job was queued while the gateway was down (restart, pairing issue, etc.) and is now stale. Harmless -- the next scheduled occurrence will be created correctly. No action needed.

### CLI commands fail with "pairing required"

**Symptom**: `openclaw devices list`, `openclaw gateway status`, etc. fail even though cron and Telegram work fine.

**Cause**: This is a known quirk. CLI RPC commands use a separate WebSocket connection that enforces device pairing even on loopback. The in-process agent runtime (cron, Telegram, tools) is NOT affected -- it runs inside the gateway process.

**Workaround**: Use `openclaw doctor` (reads state directly, no RPC) or interact via Telegram. This is cosmetic and does not affect agent functionality.

---

## Migration History

Merlin migrated from hsb1 (Nix package, `systemd.services.openclaw-gateway`) to hsb0 (Docker) on 2026-02-13. Full cleanup of hsb1 infrastructure completed 2026-02-14.

- **Migration backlog**: `hosts/hsb0/docs/backlog/P30--438b3b8--migrate-merlin-openclaw-to-hsb0-docker.md`
- **hsb1 on-host state** (`~/.openclaw/`) kept as backup until 2026-03-14

## Git vs Host State

**What goes in git (workspace repo):**

The workspace (`/home/node/.openclaw/workspace/`) is version-controlled in a separate git repo (`markus-barta/oc-workspace-merlin`). This includes:

- `skills/` - Skill definitions
- `memory/` - Agent's learned knowledge
- `IDENTITY.md` - Agent identity
- `HEARTBEAT.md` - Agent self-awareness
- `workbench/` - Working files
- `AGENTS.md` - Git workflow instructions

**What stays in `/var/lib/` (NOT in git):**

All other files in `/var/lib/openclaw-merlin/` are runtime state and never go into git:

| Directory/File  | Why                                          |
| --------------- | -------------------------------------------- |
| `openclaw.json` | Gateway config - infrastructure, not content |
| `credentials/`  | Secrets - handled by agenix                  |
| `telegram/`     | Runtime state (updates, offsets)             |
| `cron/`         | Operational logs and jobs                    |
| `devices/`      | Paired device state                          |
| `vdirsyncer/`   | External tool config                         |
| `khal/`         | External tool config                         |
| `gogcli/`       | External tool config                         |

The workspace repo is for **content the agent creates** (skills, memory, identity). The `/var/lib/` is for **infrastructure and runtime state** that should not be version-controlled.

## Workspace Git Workflow

### Overview

Both AI agents (Merlin on hsb0, Percy on miniserver-bp) have git-backed workspaces. Each agent pushes via its own GitHub account. Markus edits all three repos locally in a single VSCodium workspace.

| Component        | Repo                               | GitHub account       | Local clone                  |
| ---------------- | ---------------------------------- | -------------------- | ---------------------------- |
| Nix infra config | `markus-barta/nixcfg`              | `@markus-barta`      | `~/Code/nixcfg`              |
| Merlin workspace | `markus-barta/oc-workspace-merlin` | `@merlin-ai-mba`     | `~/Code/oc-workspace-merlin` |
| Percy workspace  | `bytepoets-mba/oc-workspace-percy` | `@bytepoets-percyai` | `~/Code/oc-workspace-percy`  |

**Combined VSCodium workspace**: `nixcfg+agents.code-workspace` (all three repos as roots).

### Flows

**Agent writes** (Merlin or Percy):

1. Agent edits workspace files during conversation
2. Agent decides when to `git add/commit/push`
3. Daily auto-push safety net catches uncommitted changes (background loop in entrypoint)
4. Markus sees changes via `git pull` in local clone

**Markus writes**:

1. Markus edits in VSCodium (any of the three roots)
2. Commits + pushes to GitHub
3. Agent picks up changes via `just <agent>-pull-workspace` or on container restart

### Just Recipes (from imac0 or hsb0)

```bash
just merlin-stop              # stop container process
just merlin-start             # start container process
just merlin-pull-workspace    # git pull inside running container
just merlin-rebuild           # rebuild + recreate container
just merlin-status            # container status + recent logs
```

Percy recipes (`percy-stop`, `percy-pull-workspace`, etc.) follow the same pattern on miniserver-bp.

### Container Git Setup

Each container's entrypoint:

- Clones workspace repo on first boot (using PAT from agenix secret)
- Pulls latest on subsequent boots (`git pull --ff-only`)
- Configures git identity (name + noreply email)
- Starts daily auto-push background loop (`sleep 86400` cycle)

PATs are stored in agenix, mounted as docker secrets at `/run/secrets/github-pat`.

### Local Setup (imac0, mba-imac-work)

- Clones at `~/Code/oc-workspace-merlin` and `~/Code/oc-workspace-percy`
- Each workspace has its own `.envrc` loading `GH_TOKEN` from macOS Keychain:
  - nixcfg + Merlin: `gh-token-markus-barta` → `@markus-barta`
  - Percy: `gh-token-bytepoets-mba` → `@bytepoets-mba`
- direnv auto-switches identity based on working directory
- Open `nixcfg+agents.code-workspace` in VSCodium for all three repos

## Related Documentation

- [hsb0 RUNBOOK](./RUNBOOK.md) - Main host runbook
- [Percy OPENCLAW-RUNBOOK](../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md) - Sister instance (miniserver-bp)
- [Migration Backlog (P30)](../backlog/P30--438b3b8--migrate-merlin-openclaw-to-hsb0-docker.md)
- [iCal Sync Fix (P40)](../backlog/P40--0c5e66c--ical-sync-fix.md)
