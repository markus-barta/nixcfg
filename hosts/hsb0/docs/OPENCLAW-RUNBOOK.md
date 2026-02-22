# OpenClaw Runbook - hsb0

**Host**: hsb0 (192.168.1.99)
**Agents**: Merlin + Nimue (multi-agent gateway)
**Port**: 18789
**Management**: docker-compose
**Version**: latest (npm)
**Updated**: 2026-02-21

---

## Architecture

```
docker-compose.yml → Docker → node:22-bookworm-slim + openclaw@latest
                                ↓
                    openclaw-gateway (single container, --network=host)
                    ├── Agent: merlin  → workspace-merlin, agents/merlin/
                    └── Agent: nimue   → workspace-nimue,  agents/nimue/
                                ↓
                    /var/lib/openclaw-gateway/data (host volume)
```

- Single container `openclaw-gateway` runs both agents via OpenClaw native multi-agent routing
- Image built from `docker/openclaw-gateway/Dockerfile`
- All state persisted at `/var/lib/openclaw-gateway/`
- Secrets injected via agenix-mounted files → entrypoint builds per-agent env
- `openclaw.json` is git-managed (`docker/openclaw-gateway/openclaw.json`), deployed by entrypoint on boot
- `tools.sessions.visibility = "all"` + `tools.agentToAgent` enable real-time `sessions_send`

### Secret Handling

1. **Agenix** decrypts secrets to `/run/agenix/hsb0-openclaw-*` and `/run/agenix/hsb0-nimue-*`
2. **Compose** mounts secrets as ro volumes to `/run/secrets/*`
3. **Entrypoint** builds per-agent env (shared: OpenRouter, Brave, HASS; unique: Telegram token, GitHub PAT, gogcli account)
4. **openclaw.json** references via `${ENV_VAR}` (no plaintext tokens)

---

## Current Status

| Component       | Agent  | Status        | Notes                             |
| --------------- | ------ | ------------- | --------------------------------- |
| Container       | both   | ✅ Running    | Docker, `--network=host`          |
| Telegram        | Merlin | ✅ Connected  | @merlin_oc_bot                    |
| Telegram        | Nimue  | ✅ Connected  | Nimue's bot                       |
| Agent-to-Agent  | both   | ✅ Working    | `sessions_send` real-time comms   |
| Home Assistant  | Merlin | ✅ Working    | HASS at 192.168.1.101:8123        |
| Brave Search    | both   | ✅ Working    | Shared key                        |
| Cron            | Merlin | ✅ Working    | Built-in scheduler                |
| iCloud Calendar | Merlin | ❌ Broken     | vdirsyncer sync needs fix         |
| iCloud Calendar | Nimue  | ❌ Not setup  | Credentials mounted, needs config |
| M365 Calendar   | Merlin | ❌ Not setup  | Azure AD app not yet created      |
| Google (gogcli) | Nimue  | ❌ Not setup  | Credentials mounted, needs auth   |
| Opus Gateway    | Merlin | ✅ Configured | Credentials mounted from agenix   |

## Available Skills

### Merlin (workspace: `oc-workspace-merlin`)

| Skill                  | Description                             |
| ---------------------- | --------------------------------------- |
| calendar               | CalDAV sync (iCloud, vdirsyncer + khal) |
| home-assistant         | Control Home Assistant (192.168.1.101)  |
| opus-gateway           | EnOcean devices via Opus Gateway        |
| openrouter-free-models | Find free LLMs on OpenRouter            |

### Nimue (workspace: `oc-workspace-nimue`)

Nimue uses OpenClaw bundled skills (gog, weather, skill-creator, healthcheck).
User-installed skills can be added to her workspace as needed.

```bash
# List skills for a specific agent
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw skills list --agent merlin'
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw skills list --agent nimue'
```

---

## Operational Commands

### Update to Latest Version

```bash
just oc-rebuild
# Runs: docker compose build --no-cache && docker compose up -d --force-recreate
# --no-cache ensures npm pulls openclaw@latest (not a cached layer)
```

### Check Status

```bash
just oc-status                          # from imac0 or hsb0

# Or directly on hsb0:
docker ps | grep openclaw-gateway
docker logs -f openclaw-gateway
curl http://192.168.1.99:18789/health
```

### Restart (no rebuild)

```bash
just oc-stop && just oc-start

# Or directly on hsb0:
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose restart openclaw-gateway
```

### Full Deploy (nixcfg config changes + container rebuild)

```bash
# On hsb0:
gitpl && just switch && just oc-rebuild
# gitpl = git pull + submodule update (fish alias)
# just switch = sudo nixos-rebuild switch --flake .#hsb0
# just oc-rebuild = build --no-cache + recreate container
```

### View Live Config

```bash
# Git-managed source (what gets deployed on next boot)
cat ~/Code/nixcfg/hosts/hsb0/docker/openclaw-gateway/openclaw.json | jq

# Live config in running container
docker exec openclaw-gateway cat /home/node/.openclaw/openclaw.json | jq
```

---

## Telegram Operations

### Pairing (per-agent)

```bash
# Merlin
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing list telegram --agent merlin'
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing approve telegram <CODE> --agent merlin'

# Nimue
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing list telegram --agent nimue'
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing approve telegram <CODE> --agent nimue'
```

---

## Home Assistant

Token mounted at `/run/secrets/hass-token` (shared by both agents).

```bash
docker exec openclaw-gateway sh -c \
  'curl -s -H "Authorization: Bearer $(cat /run/secrets/hass-token)" \
   http://192.168.1.101:8123/api/states | jq length'
```

---

## Opus Gateway

Credentials mounted from agenix:

- Host: `/run/agenix/hsb0-openclaw-opus-gateway`
- Container: `/home/node/.openclaw/credentials/opus-gateway.env`

---

## Secrets (Agenix)

### Shared (both agents)

| Secret                         | Purpose             | Container path                 |
| ------------------------------ | ------------------- | ------------------------------ |
| `hsb0-openclaw-gateway-token`  | Gateway WS auth     | `/run/secrets/gateway-token`   |
| `hsb0-openclaw-openrouter-key` | LLM inference       | `/run/secrets/openrouter-key`  |
| `hsb0-openclaw-hass-token`     | Home Assistant LLAT | `/run/secrets/hass-token`      |
| `hsb0-openclaw-brave-key`      | Brave Search API    | `/run/secrets/brave-key`       |
| `hsb0-openclaw-opus-gateway`   | Opus gateway creds  | `credentials/opus-gateway.env` |

### Merlin-specific

| Secret                          | Purpose                 | Container path                         |
| ------------------------------- | ----------------------- | -------------------------------------- |
| `hsb0-openclaw-telegram-token`  | Merlin's Telegram bot   | `/run/secrets/telegram-token-merlin`   |
| `hsb0-openclaw-github-pat`      | Merlin's GitHub PAT     | `/run/secrets/github-pat-merlin`       |
| `hsb0-openclaw-icloud-password` | iCloud CalDAV           | Not yet wired to vdirsyncer            |
| `hsb0-gogcli-keyring-password`  | Merlin's gogcli keyring | `/run/secrets/gogcli-keyring-password` |

### Nimue-specific

| Secret                               | Purpose                 | Container path                               |
| ------------------------------------ | ----------------------- | -------------------------------------------- |
| `hsb0-nimue-telegram-token`          | Nimue's Telegram bot    | `/run/secrets/telegram-token-nimue`          |
| `hsb0-nimue-github-pat`              | Nimue's GitHub PAT      | `/run/secrets/github-pat-nimue`              |
| `hsb0-nimue-icloud-password`         | Mailina's iCloud CalDAV | `/run/secrets/icloud-password-nimue`         |
| `hsb0-nimue-gogcli-keyring-password` | Nimue's gogcli keyring  | `/run/secrets/gogcli-keyring-password-nimue` |

All secrets are `mode = "444"` in NixOS config for Docker read access.

---

## Files Reference

| What                       | Location                                                     |
| -------------------------- | ------------------------------------------------------------ |
| Dockerfile                 | `hosts/hsb0/docker/openclaw-gateway/Dockerfile`              |
| entrypoint.sh              | `hosts/hsb0/docker/openclaw-gateway/entrypoint.sh`           |
| openclaw.json (git source) | `hosts/hsb0/docker/openclaw-gateway/openclaw.json`           |
| docker-compose             | `hosts/hsb0/docker/docker-compose.yml`                       |
| NixOS config               | `hosts/hsb0/configuration.nix`                               |
| Live config                | `/var/lib/openclaw-gateway/data/openclaw.json`               |
| Merlin workspace           | `/var/lib/openclaw-gateway/data/workspace-merlin/`           |
| Nimue workspace            | `/var/lib/openclaw-gateway/data/workspace-nimue/`            |
| Merlin agent state         | `/var/lib/openclaw-gateway/data/agents/merlin/`              |
| Nimue agent state          | `/var/lib/openclaw-gateway/data/agents/nimue/`               |
| Merlin external tools      | `/var/lib/openclaw-gateway/merlin-{vdirsyncer,khal,gogcli}/` |
| Nimue external tools       | `/var/lib/openclaw-gateway/nimue-{vdirsyncer,khal,gogcli}/`  |
| Container logs             | `docker logs openclaw-gateway`                               |
| Secrets (agenix)           | `secrets/hsb0-openclaw-*.age`, `secrets/hsb0-nimue-*.age`    |

## Access

| Service    | Agent  | URL / Handle               |
| ---------- | ------ | -------------------------- |
| Control UI | both   | http://192.168.1.99:18789/ |
| Telegram   | Merlin | @merlin_oc_bot             |
| Telegram   | Nimue  | Nimue's bot                |

---

## Troubleshooting

### "pairing required" — cron/tools fail after fresh deploy

**Symptom**:

```
[tools] cron failed: gateway closed (1008): pairing required
```

**Root cause**: Agent's internal client not registered as paired device. Happens for BOTH agents on first boot after container rebuild.

**Diagnosis**:

```bash
# Check both agents
docker exec openclaw-gateway cat /home/node/.openclaw/agents/merlin/agent/devices/paired.json
docker exec openclaw-gateway cat /home/node/.openclaw/agents/merlin/agent/devices/pending.json
docker exec openclaw-gateway cat /home/node/.openclaw/agents/nimue/agent/devices/pending.json
```

**Fix**: Copy pending → paired manually, then restart:

```bash
# 1. Read pending device (replace AGENT with merlin or nimue)
docker exec openclaw-gateway cat /home/node/.openclaw/agents/AGENT/agent/devices/pending.json | jq

# 2. Write paired.json with deviceId + publicKey from above
docker exec openclaw-gateway sh -c 'echo "{\"DEVICE_ID\":{...}}" > /home/node/.openclaw/agents/AGENT/agent/devices/paired.json'

# 3. Restart
docker restart openclaw-gateway
```

### "Session send visibility is restricted"

**Symptom**: `Session send visibility is restricted. Set tools.sessions.visibility=all`

**Fix**: Ensure `openclaw.json` has `tools.sessions.visibility = "all"`. Check:

```bash
docker exec openclaw-gateway python3 -c "import json; d=json.load(open('/home/node/.openclaw/openclaw.json')); print(d['tools']['sessions'])"
# Expected: {'visibility': 'all'}
```

If missing, `just oc-rebuild` to redeploy git-managed config.

### "All models failed / Provider in cooldown"

**Symptom**: `FailoverError: 403 Key limit exceeded` or `Provider openrouter is in cooldown`.

**Diagnosis**:

```bash
# Check per-agent auth-profiles (replace AGENT)
docker exec openclaw-gateway cat /home/node/.openclaw/agents/AGENT/agent/auth-profiles.json | jq

# Verify key works
curl -s https://openrouter.ai/api/v1/auth/key \
  -H "Authorization: Bearer $(cat /run/agenix/hsb0-openclaw-openrouter-key)"
```

**Fix**: Edit `auth-profiles.json` for the affected agent — remove stale `key`, reset `disabledUntil`/`errorCount`, restart.

### "schedule.at is in the past"

Harmless — stale cron job from a restart. Next occurrence fires correctly. No action needed.

### CLI commands fail with "pairing required"

Known quirk — CLI RPC enforces pairing even on loopback. In-process agent runtime (cron, Telegram) is unaffected. Use `openclaw doctor` or Telegram to interact.

---

## Migration History

- **2026-02-21**: Migrated from single-agent `openclaw-merlin` to multi-agent `openclaw-gateway`. Nimue added as second agent. See `hosts/hsb0/docs/backlog/P40--339a6f7--setup-nimue-multi-agent.md`.
- **2026-02-13**: Merlin migrated from hsb1 (Nix package) to hsb0 (Docker).

---

## Git vs Host State

**What goes in git (workspace repos):**

Each agent has a separate private GitHub repo:

| Agent  | Repo                               | Contains                                               |
| ------ | ---------------------------------- | ------------------------------------------------------ |
| Merlin | `markus-barta/oc-workspace-merlin` | skills/, memory/, IDENTITY.md, HEARTBEAT.md, AGENTS.md |
| Nimue  | `markus-barta/oc-workspace-nimue`  | skills/, memory/, IDENTITY.md, HEARTBEAT.md, AGENTS.md |

**What stays in `/var/lib/` (NOT in git):**

| Directory/File      | Why                                          |
| ------------------- | -------------------------------------------- |
| `openclaw.json`     | Gateway config — infrastructure, not content |
| `credentials/`      | Secrets — handled by agenix                  |
| `telegram/`         | Runtime state (updates, offsets)             |
| `cron/`             | Operational logs and jobs                    |
| `agents/*/devices/` | Paired device state                          |
| `*-vdirsyncer/`     | External tool config                         |
| `*-khal/`           | External tool config                         |
| `*-gogcli/`         | External tool config                         |

---

## Workspace Git Workflow

### Overview

| Component        | Repo                               | GitHub account       | Local clone                  |
| ---------------- | ---------------------------------- | -------------------- | ---------------------------- |
| Nix infra config | `markus-barta/nixcfg`              | `@markus-barta`      | `~/Code/nixcfg`              |
| Merlin workspace | `markus-barta/oc-workspace-merlin` | `@merlin-ai-mba`     | `~/Code/oc-workspace-merlin` |
| Nimue workspace  | `markus-barta/oc-workspace-nimue`  | `@nimue-ai-mai`      | `~/Code/oc-workspace-nimue`  |
| Percy workspace  | `bytepoets-mba/oc-workspace-percy` | `@bytepoets-percyai` | `~/Code/oc-workspace-percy`  |

**Combined VSCodium workspace**: `nixcfg+agents.code-workspace` (all repos as roots).

### Just Recipes (from imac0 or hsb0)

```bash
just oc-rebuild             # update + rebuild container (--no-cache, pulls latest openclaw)
just oc-status              # container status + recent logs
just oc-stop                # stop container
just oc-start               # start container
just merlin-pull-workspace  # git pull Merlin's workspace into container
just nimue-pull-workspace   # git pull Nimue's workspace into container
```

### Container Git Setup

The entrypoint handles both agents in a loop:

- Clones workspace repo on first boot (using per-agent PAT from agenix)
- Pulls latest on subsequent boots (`git pull --ff-only`)
- Configures git identity per agent (name + noreply email)
- Writes per-agent gogcli env file (`/home/node/.config/<agent>/gogcli/gogcli.env`)
- Starts daily auto-push background loop per agent

### Local Setup (imac0)

- All three workspace repos cloned under `~/Code/`
- Open `nixcfg+agents.code-workspace` in VSCodium for all repos

---

## Related Documentation

- [hsb0 RUNBOOK](./RUNBOOK.md) - Main host runbook
- [Percy OPENCLAW-RUNBOOK](../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md) - Sister instance (miniserver-bp)
- [Agent-to-Agent Comms (P40)](../backlog/P40--1681369--agent-to-agent-comms-opencode-merlin.md)
- [Git-managed openclaw.json (P40, done)](../backlog/P40--599943c--merlin-git-managed-openclaw-json.md)
