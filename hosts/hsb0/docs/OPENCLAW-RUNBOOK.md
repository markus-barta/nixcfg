# OpenClaw Runbook - hsb0

**Host**: hsb0 (192.168.1.99)
**Agents**: Merlin + Nimue (multi-agent gateway)
**Port**: 18789
**Management**: docker-compose
**Version**: 2026.3.2
**Updated**: 2026-03-07

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

| Component       | Agent  | Status          | Notes                                                            |
| --------------- | ------ | --------------- | ---------------------------------------------------------------- |
| Container       | both   | ✅ Running      | Docker, `--network=host`                                         |
| Telegram        | Merlin | ✅ Connected    | @merlin_oc_bot                                                   |
| Telegram        | Nimue  | ✅ Connected    | Nimue's bot                                                      |
| Agent-to-Agent  | both   | ✅ Working      | `sessions_send` real-time comms                                  |
| Home Assistant  | Merlin | ✅ Working      | HASS at 192.168.1.101:8123                                       |
| Brave Search    | both   | ✅ Working      | Shared key                                                       |
| Cron            | Merlin | ✅ Working      | Built-in scheduler                                               |
| iCloud Calendar | Merlin | ❌ Broken       | vdirsyncer sync needs fix                                        |
| iCloud Calendar | Nimue  | ❌ Not setup    | Credentials mounted, needs config                                |
| M365 Calendar   | Merlin | ❌ Not setup    | Azure AD app not yet created                                     |
| Google (gogcli) | Merlin | ⏳ Auth pending | Dedicated account `merlin.ai.markus@gmail.com` not yet connected |
| Google (gogcli) | Nimue  | ⏳ Auth pending | Account `nimue.ai.mailina@gmail.com` created, needs auth         |
| Opus Gateway    | Merlin | ✅ Configured   | Credentials mounted from agenix                                  |

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

## Memory Search

Memory is plain Markdown in each agent's workspace (`workspace-merlin/memory/`, `workspace-nimue/memory/`). OpenClaw indexes these files for semantic recall via `memory_search` and `memory_get` tools.

### Configuration (openclaw.json)

```json
"memorySearch": {
  "provider": "local",
  "fallback": "none"
}
```

`provider: "local"` uses a local GGUF embedding model (~328MB, auto-downloaded on first use via node-llama-cpp). No external API key required. First index run is slow; subsequent runs are fast.

**Why not OpenRouter?** OpenRouter only provides chat/completions, no embedding endpoint.

### Container build requirement

`node-llama-cpp` is an **optional** dependency of `openclaw` and **must be installed explicitly** in the Dockerfile. npm silently skips optional native deps when their build/binary-fetch fails — leaving local embeddings unavailable at runtime with the misleading "memory search broken" doctor warning. The Dockerfile lists it directly:

```dockerfile
RUN npm install -g openclaw@latest sharp node-llama-cpp@^3
```

`node:24-bookworm-slim` is the base image — Node 24 is required by the embedder's prebuilt-binary matrix (Node 22 leaves it as `UNMET OPTIONAL DEPENDENCY` even when explicitly listed).

If memory search reports unavailable after a rebuild, verify with:

```bash
docker exec openclaw-gateway sh -c 'ls /usr/local/lib/node_modules/ | grep node-llama-cpp'
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory status --deep --agent merlin'
```

Expected: `node-llama-cpp` directory present; `Embeddings: ready`, `Vector: ready (768 dims)`.

### Commands

```bash
# Check index status (all agents)
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory status'

# Check with JSON detail (shows provider, file counts, issues)
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory status --json'

# Force full reindex (after adding new memory files)
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory index --force'
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory index --force --agent nimue'

# Search (diagnostic)
docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory search "Maurice"'
```

### Memory file layout

| File                         | Purpose                             |
| ---------------------------- | ----------------------------------- |
| `memory/family.md`           | People, relationships, context      |
| `memory/infrastructure.md`   | Home automation, NixOS setup        |
| `memory/workflows.md`        | Agent workflows, sub-agent patterns |
| `memory/debug_log.md`        | Troubleshooting notes               |
| `memory/daily/YYYY-MM-DD.md` | Daily logs (auto-created by agent)  |

### Workspace root files

| File           | Purpose                               |
| -------------- | ------------------------------------- |
| `SOUL.md`      | Identity, tone, character, boundaries |
| `USER.md`      | About the human — rich context        |
| `TOOLS.md`     | Environment-specific tool notes       |
| `AGENTS.md`    | Git workflow instructions             |
| `HEARTBEAT.md` | Scheduled/recurring tasks             |
| `IDENTITY.md`  | Name, emoji, vibe summary             |

### First-boot note

On first start after enabling local embeddings, the GGUF model downloads automatically (~328MB). During this time `memory status` shows `provider: local, files: 0`. Wait for download to complete, then run `openclaw memory index --force`. Check container logs to monitor progress. Model path: `~/.node-llama-cpp/models/hf_ggml-org_embeddinggemma-300m-qat-Q8_0.gguf`.

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
curl -k https://192.168.1.99:18789/health
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

## Rotate an API Key / Secret

Secrets flow: `.age` file (git) -> agenix decrypt (`/run/agenix/`) -> Docker mount (`/run/secrets/`) -> entrypoint (`.env` + `auth-profiles.json`). All layers must be refreshed.

```bash
# 1. On your Mac (encrypt new value):
agenix -e secrets/hsb0-openclaw-<secret-name>.age

# 2. Commit + push:
git add secrets/hsb0-openclaw-<secret-name>.age && git commit -m "secrets: rotate <secret>" && git push

# 3. On hsb0 (all three steps required!):
gitpl && just switch && just oc-rebuild
#   gitpl       = pulls the new .age file
#   just switch = agenix re-decrypts to /run/agenix/ (REQUIRED — without this the old key stays!)
#   oc-rebuild  = container picks up the new secret from /run/secrets/
```

> **Common mistake:** skipping `just switch` after updating a `.age` file. `oc-rebuild` alone only rebuilds the container — agenix secrets are decrypted by NixOS, not Docker.

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

> ⚠️ **2026.2.26 change**: flag is `--account`, not `--agent`. `--agent` no longer exists in this version.

```bash
# Merlin
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing list telegram --account merlin'
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing approve telegram <CODE> --account merlin'

# Nimue
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing list telegram --account nimue'
docker exec -it openclaw-gateway sh -c '. /home/node/.env && openclaw pairing approve telegram <CODE> --account nimue'
```

---

## Home Assistant

Token mounted at `/run/secrets/hass-token` (shared by both agents).

```bash
docker exec openclaw-gateway sh -c \
  'curl -s -H "Authorization: Bearer $(cat /run/secrets/hass-token)" \
   http://192.168.1.101:8123/api/states | jq length'
```

### Merlin SSH Access to hsb1

Merlin has direct SSH access to **hsb1** (home automation host) as the `merlin` user.

- **User**: `merlin` (uid=1002, `wheel` + `docker` groups — full host access)
- **Key**: `/home/node/.ssh/merlin-hsb1` (copied from agenix at container boot)
- **SSH config**: `/home/node/.ssh/config` → `Host hsb1 hsb1.lan`

```bash
# Test connectivity
docker exec openclaw-gateway ssh hsb1.lan "hostname && whoami"

# Edit HA config (sudo required — /home/mba is 0700, some files are root:root)
docker exec openclaw-gateway ssh hsb1.lan "sudo nano /home/mba/docker/mounts/homeassistant/configuration.yaml"

# Restart HA (full path required for docker compose)
docker exec openclaw-gateway ssh hsb1.lan "sudo docker compose -f /home/mba/docker/docker-compose.yml restart homeassistant"

# docker exec into HA (no sudo needed)
docker exec openclaw-gateway ssh hsb1.lan "docker exec homeassistant ha core check"

# Reset known_hosts if hsb1 was rebuilt
docker exec openclaw-gateway ssh-keygen -R hsb1.lan
```

> ⚠️ `/home/mba` is `0700` — all paths under it require `sudo`. Direct `docker` commands work without sudo (merlin is in docker group).

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

| Secret                          | Purpose                 | Container path                                                                  |
| ------------------------------- | ----------------------- | ------------------------------------------------------------------------------- |
| `hsb0-openclaw-telegram-token`  | Merlin's Telegram bot   | `/run/secrets/telegram-token-merlin`                                            |
| `hsb0-openclaw-icloud-password` | iCloud CalDAV           | Not yet wired to vdirsyncer                                                     |
| `hsb0-gogcli-keyring-password`  | Merlin's gogcli keyring | `/run/secrets/gogcli-keyring-password`                                          |
| `hsb0-merlin-ssh-key`           | SSH key for hsb1 access | `/run/secrets/merlin-ssh-key` (copied to `/home/node/.ssh/merlin-hsb1` at boot) |

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

| Service    | Agent  | URL / Handle                | Network         |
| ---------- | ------ | --------------------------- | --------------- |
| Control UI | both   | https://192.168.1.99:18789/ | Home LAN        |
| Control UI | both   | https://100.64.0.6:18789/   | Tailscale (any) |
| Telegram   | Merlin | @merlin_oc_bot              | —               |
| Telegram   | Nimue  | @nimue_oc_bot               | —               |

### Control UI access notes

- `bind: "lan"` — gateway binds to `0.0.0.0`; listens on loopback, LAN IP, and Tailscale IP
- `tailscale.mode: "off"` — no Tailscale Serve/Funnel; direct bind only (works with Headscale)
- `gateway.tls.enabled: true` — built-in self-signed TLS (RSA-2048, 10-year cert, auto-generated, stored in data volume)
- Trust model: browser shows cert warning on first visit; click "proceed anyway" once per browser profile
- Device pairing required on first browser visit (HTTPS secure context — browsers require HTTPS for the crypto/storage APIs the Control UI uses)
- No `OPENCLAW_GATEWAY_URL` env var in docker-compose — CLI auto-discovers `ws://127.0.0.1:18789`

### Why bind: "lan" (not "tailnet")

`bind: "tailnet"` only listens on `100.64.0.6` — loopback is dead. CLI inside the container
then can't reach the gateway on `ws://127.0.0.1`. The workaround of setting
`OPENCLAW_GATEWAY_URL=wss://100.64.0.6:18789` causes the CLI to enter "explicit connection mode",
which ignores `gateway.remote.tlsFingerprint` from config → TLS cert not trusted → WebSocket 1006.

`bind: "lan"` = `0.0.0.0`: gateway listens on all interfaces simultaneously. CLI uses loopback
(no TLS, no fingerprint needed), browser uses Tailscale IP (TLS, cert warning once).

Bind mode source behavior (verified in bundle source `net-Bf8Z-b6p.js`):

| mode       | binds to                              |
| ---------- | ------------------------------------- |
| `loopback` | `127.0.0.1`                           |
| `lan`      | `0.0.0.0` (all interfaces) ✅ current |
| `tailnet`  | Tailscale IPv4 only (loopback dead)   |
| `auto`     | `127.0.0.1` only (loopback fallback)  |
| `custom`   | single user-specified IP              |

### Device pairing (browser, one-time per browser profile)

**Step 1** — Get the dashboard URL with token embedded (CLI outputs `http://127.0.0.1:...` — swap the IP):

```bash
docker exec openclaw-gateway openclaw dashboard --no-open
# Output: Dashboard URL: http://127.0.0.1:18789/#token=<token>
# Manually change to: https://100.64.0.6:18789/#token=<token>
```

**Step 2** — Open the corrected URL in your browser. Accept the cert warning. This seeds the token into browser storage.

**Step 3** — The browser sends a device pairing request. Approve it:

```bash
docker exec openclaw-gateway openclaw devices list
docker exec openclaw-gateway openclaw devices approve --latest
```

No `--url`, `--token`, or `--tls-fingerprint` flags needed — CLI connects to `ws://127.0.0.1:18789`
automatically (no TLS in play for internal connections).

> `dashboard --no-open` always prints `http://127.0.0.1` because the CLI uses loopback. The token
> in the URL fragment is what matters — swap the IP to the Tailscale or LAN address before opening.

---

## gogcli Auth (Merlin — dedicated Google account)

### Agent Google Identities

| Agent  | Gmail account                | Owner   |
| ------ | ---------------------------- | ------- |
| Merlin | `merlin.ai.markus@gmail.com` | Markus  |
| Nimue  | `nimue.ai.mailina@gmail.com` | Mailina |

### Background

- gog version: `v0.11.0 (91c4c15 2026-02-15)`
- `GOG_CONFIG_DIR` env var is **ignored** — config always goes to `/home/node/.config/gogcli/`
- Merlin's target account is **`merlin.ai.markus@gmail.com`**
- old Google Cloud project was deleted; current setup is a clean start from scratch
- gog requires the exact authorized email; alias mismatches fail before token persistence
- `--remote --step 2 --auth-url '<redirect-url>'` is the correct flow — paste the full redirect URL from the browser address bar after OAuth
- ⚠️ Previous note said `--remote --step 2` had a "confirmed bug" (`manual auth state mismatch`) — likely caused by email mismatch (`markus@barta.com` vs `markus.barta@gmail.com`), not a gog bug. `--auth-code` workaround probably unnecessary.
- No SSH tunnel needed — use `--auth-url` with the full redirect URL instead
- gog writes tokens to `/home/node/.config/gogcli/keyring/`; copy them to Merlin's mounted config dir after auth

### Auth Procedure

**Terminal 1 — container shell:**

```bash
ssh mba@hsb0.lan
docker exec -it openclaw-gateway bash
. /home/node/.config/merlin/gogcli/gogcli.env
rm -f /home/node/.config/gogcli/oauth-manual-state-*.json
gog auth add merlin.ai.markus@gmail.com --services calendar,drive,gmail,contacts,sheets,docs --remote
```

Note the **PORT** in the printed auth URL (e.g. `redirect_uri=http%3A%2F%2F127.0.0.1%3AXXXXX`).

**Terminal 2 — SSH tunnel (Mac):**

```bash
ssh -L PORT:127.0.0.1:PORT mba@hsb0.lan
# Keep this open during the whole OAuth flow
```

**Browser (Mac):** Open the auth URL, sign in as `merlin.ai.markus@gmail.com`, grant all scopes. Browser will show "connection refused" on redirect — that's expected. From the address bar, copy **only the `code=` parameter value** (starts with `4/0A...`, ends before `&scope=`).

**Terminal 1 — complete auth:**

```bash
. /home/node/.config/merlin/gogcli/gogcli.env
gog auth add merlin.ai.markus@gmail.com --services calendar,drive,gmail,contacts,sheets,docs --auth-code 'PASTE_CODE_HERE'
```

**Verify:**

```bash
gog auth list
gog gmail list inbox --limit 1
```

**Persist token (survives container rebuilds):**

```bash
cp -r /home/node/.config/gogcli/keyring/ /home/node/.config/merlin/gogcli/keyring/
```

The host volume at `/var/lib/openclaw-gateway/merlin-gogcli/` is mounted to `/home/node/.config/merlin/gogcli/` — anything copied there survives rebuilds.

See also `hosts/hsb0/docs/OPENCLAW-GOGCLI.md` for Google Console setup, known traps, and persistence notes.

### Files (in container)

| File                                          | Purpose                                               |
| --------------------------------------------- | ----------------------------------------------------- |
| `/home/node/.config/merlin/gogcli/gogcli.env` | Merlin's gogcli env — source before any `gog` command |
| `/home/node/.config/gogcli/credentials.json`  | Google OAuth credentials (installed-app format)       |
| `/home/node/.config/gogcli/keyring/`          | Token location (transient — copy to below after auth) |
| `/home/node/.config/merlin/gogcli/keyring/`   | Persistent token location (host volume)               |

### Re-auth (token expired)

Delete stale state + keyring, then repeat the procedure above:

```bash
rm -f /home/node/.config/gogcli/oauth-manual-state-*.json
rm -f /home/node/.config/gogcli/keyring/*
rm -f /home/node/.config/merlin/gogcli/keyring/*
```

---

## Troubleshooting

### Doctor warning: "groupPolicy is allowlist but groupAllowFrom is empty"

**Symptom**: CLI commands print warnings like:

```
- channels.telegram.accounts.merlin.groupPolicy is "allowlist" but
  groupAllowFrom (and allowFrom) is empty — all group messages will be
  silently dropped.
```

**Intentional.** Merlin and Nimue are DM-only bots. Group chat is disabled by design (`groupPolicy: "allowlist"` + empty `groupAllowFrom`). Ignore this warning.

If group access is ever needed: add Telegram user/group IDs to `groupAllowFrom` in `openclaw.json`, or set `groupPolicy: "open"`.

---

### Doctor warning: "Moved channels.telegram single-account top-level values"

**Symptom**: Every CLI command prints:

```
◇  Doctor changes
│  Moved channels.telegram single-account top-level values into
│  channels.telegram.accounts.default.
```

**This is a false positive.** Our `openclaw.json` already uses the correct `accounts.<id>` format. The warning is triggered by a legacy runtime state file. Fix:

```bash
# Rename the old file (already done 2026-02-27, here for reference)
docker exec openclaw-gateway mv \
  /home/node/.openclaw/credentials/telegram-allowFrom.json \
  /home/node/.openclaw/credentials/telegram-allowFrom.json.old
```

If it persists after a rebuild, the entrypoint may be recreating it — check `entrypoint.sh`.

### Control UI: "origin not allowed" (Tailscale IP)

**Symptom**: Accessing Control UI via Tailscale IP (`100.64.0.x`) returns:

```
code=1008 reason=origin not allowed
```

**Cause**: `gateway.controlUi.allowedOrigins` only allows `http://192.168.1.99:18789`. Tailscale uses a different IP.

**Workaround**: Access via LAN IP `http://192.168.1.99:18789` directly, or add the Tailscale origin to `allowedOrigins` in `openclaw.json`.

### Control UI: "requires device identity" / "requires HTTPS or localhost"

**Symptom**: Browser shows "Control UI requires device identity" when opening via HTTP.

**Root cause (2026.3.2)**: The Control UI uses `crypto`/`storage` browser APIs that require a **secure context** (HTTPS or localhost). HTTP access from non-loopback IPs no longer works regardless of `dangerouslyDisableDeviceAuth`.

**Fix**: Enable `gateway.tls.enabled: true` and `gateway.bind: "lan"` in `openclaw.json`. See "Control UI access notes" and "Why bind: lan" in the Access section above.

**Config required**:

```json
"gateway": {
  "bind": "lan",
  "tls": { "enabled": true },
  "remote": {
    "url": "wss://100.64.0.6:18789",
    "tlsFingerprint": "<sha256-from-first-boot-logs>"
  }
}
```

`remote.url` and `remote.tlsFingerprint` are used by external CLI clients connecting from outside
the container. Internal CLI (inside container) uses `ws://127.0.0.1:18789` automatically.

### Telegram pairing broke after upgrade

> **Update 2026-04-19**: Pairings for both Merlin and Nimue **survived** the upgrade from 2026.4.8 → 2026.4.15. The "always lost on upgrade" guidance below is from the 2026.2.26 era and may no longer apply. Still pre-stage the re-pair commands in case a future upgrade reverts the behavior — but expect pairings to persist.

After upgrading to 2026.2.26, existing Telegram pairings are lost. Re-pair:

```bash
# Agent sends a pairing code in Telegram — use that code below
docker exec -it openclaw-gateway sh -c \
  '. /home/node/.env && openclaw pairing approve telegram <CODE> --account merlin'
# Replace --account merlin with --account nimue for Nimue
```

> ⚠️ Flag is `--account` (not `--agent` — that flag no longer exists in 2026.2.26).

### Troubleshooting

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

- **2026-04-19**: Bundled maintenance window (NIX-74). Upgraded OpenClaw 2026.4.8 → 2026.4.15 and Node 22 → 24 in the openclaw-gateway image (single Dockerfile change covers both, since the Node bump exists only to satisfy node-llama-cpp's prebuilt-binary matrix). Memory search now works locally for both agents (NIX-70). **Two builds required**: first build kept Node 24 + openclaw@latest but left `node-llama-cpp` as `UNMET OPTIONAL DEPENDENCY` because npm silently skips optional native builds; fix-forward listed `node-llama-cpp@^3` explicitly in the npm install line. **Telegram pairings survived** for both bots (vs. RUNBOOK §564 prediction) — re-pair commands were pre-staged but unused. `dreaming.storage.mode` default flipped inline → `separate` upstream — accepted new default. Telegram round-trip latency dropped 3718ms → 73ms. doctor --fix only installed shell completion. ACP/sub-agent capability (NIX-73) was pulled from this window after Anthropic's 2026-04-04 ToS change blocked Pro/Max OAuth in claude-agent-acp; NIX-73 now parked as foundational ticket awaiting a non-Anthropic ACP target (codex / gemini-cli / planned 4-Mac-mini exo-cluster).
- **2026-03-07**: Upgraded to OpenClaw 2026.3.2. Breaking changes: (1) `dangerouslyDisableDeviceAuth` no longer bypasses device auth for non-loopback origins — removed. (2) `ws://` hardened to loopback-only — mitigated by `bind: "lan"`. (3) `gateway.tls.enabled: true` added — built-in self-signed TLS (RSA-2048, 10-year cert). Control UI now requires HTTPS (browser secure context). `bind` changed from `"tailnet"` to `"lan"` (`0.0.0.0`) so CLI inside container uses `ws://127.0.0.1` (no TLS/fingerprint needed) while browser uses `wss://100.64.0.6:18789`. Removed `OPENCLAW_GATEWAY_URL` env var from docker-compose (was causing TLS fingerprint resolution failure in explicit connection mode).
- **2026-02-22**: Merlin SSH access to hsb1 added. Dedicated `merlin` user on hsb1 (wheel + docker). Follow-up tracking moved to PPM.
- **2026-02-21**: Migrated from single-agent `openclaw-merlin` to multi-agent `openclaw-gateway`. Nimue added as second agent. Follow-up tracking moved to PPM.
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
| Merlin workspace | `markus-barta/oc-workspace-merlin` | `@merlin-ai-markus`  | `~/Code/oc-workspace-merlin` |
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

- Clones workspace repo on first boot when a per-agent PAT is configured
- Pulls latest on subsequent boots (`git pull --ff-only`) when PAT is present
- Configures git identity per agent (name + noreply email)
- Writes per-agent gogcli env file (`/home/node/.config/<agent>/gogcli/gogcli.env`)
- Starts daily auto-push background loop per agent; Merlin push is currently disabled until a replacement PAT is added

### Local Setup (imac0)

- All three workspace repos cloned under `~/Code/`
- Open `nixcfg+agents.code-workspace` in VSCodium for all repos

---

## FleetCom Observability (FLEET-36)

OpenClaw turn/tool/reply activity is surfaced in the FleetCom
dashboard via the **agent-bridge** sidecar. It runs alongside
`openclaw-gateway` on hsb0, tails its docker logs, converts
structured lines into generic agent-events, and publishes them to
FleetCom on two channels:

- `GET /v1/agent-state` on `:9180` — scraped by `fleetcom-bosun` each
  heartbeat (60s).
- `POST /api/agent-events` to `https://fleet.barta.cm` — real-time
  lifecycle push (turn started, tool invoked, replied, errored).

### Wiring

1. Deploy the bridge container on hsb0 (see
   [`agent-bridge/docker-compose.sample.yml`](https://github.com/markus-barta/fleetcom/tree/main/agent-bridge)).
2. Add `OPENCLAW_STATE_URL=http://agent-bridge:9180/v1/agent-state`
   to the `fleetcom-bosun` service env on hsb0.
3. Share `FLEETCOM_TOKEN` (the host's Bosun bearer) with the bridge.

### What shows up on the dashboard

- Rich agent chip: `merlin · BUSY 12m · claude-cli → hsb1`
- Agent drawer (click the chip): current turn span, last 50 turns,
  per-chat last-reply, recent errors, model/prompt config.
- Global **ACTIVITY** drawer (header button): live event stream
  across all agents with filters by agent/kind/severity, pause/resume.
- **STUCK** detector: card border pulses red + sticky toast when a
  turn runs >`stuck_threshold_sec` (default 120s) without any event
  for >`stuck_silence_sec` (default 120s).

### Debugging when the dashboard goes quiet

Ranked by likelihood:

1. **Log format drift.** OpenClaw rotates a field name and the
   regex patterns stop matching. Tail `docker logs openclaw-gateway`,
   compare against the patterns in
   [`agent-bridge/cmd/agent-bridge/patterns.go`](https://github.com/markus-barta/fleetcom/blob/main/agent-bridge/cmd/agent-bridge/patterns.go),
   adjust, redeploy.
2. **Bridge can't reach FleetCom.** `docker logs fleetcom-agent-bridge`
   shows `event dropped after 3 retries`. Check `FLEETCOM_URL`,
   `FLEETCOM_TOKEN`, outbound HTTPS from hsb0.
3. **Bosun not scraping.** `OPENCLAW_STATE_URL` env var missing, or
   bridge not on the same docker network. Test:
   `docker exec fleetcom-bosun wget -qO- http://agent-bridge:9180/v1/agent-state`.
4. **Excerpts not showing** in the dashboard — set `emitExcerpts:
true` in the agent's `openclaw.json` config block. Default is off
   (metadata-only by privacy policy).
5. **STUCK false-positive** on a legitimately long-running tool — the
   wrapper isn't emitting any observable log line. Either log
   `typing.refreshed` periodically, or raise `stuck_silence_sec` in
   the snapshot's `config` block.

Canonical schema reference:
[`fleetcom/docs/AGENT-OBSERVABILITY.md`](https://github.com/markus-barta/fleetcom/blob/main/docs/AGENT-OBSERVABILITY.md).

---

## Related Documentation

- [hsb0 RUNBOOK](./RUNBOOK.md) - Main host runbook
- [Percy OPENCLAW-RUNBOOK](../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md) - Sister instance (miniserver-bp)
- [OpenClaw gogcli Notes](./OPENCLAW-GOGCLI.md) - Merlin gogcli knowledge base
- Agent-to-agent comms follow-up: tracked in PPM
- Git-managed `openclaw.json` follow-up: tracked in PPM
- [FleetCom Agent Observability schema](https://github.com/markus-barta/fleetcom/blob/main/docs/AGENT-OBSERVABILITY.md) — canonical event + snapshot contract
