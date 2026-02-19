# OpenClaw Runbook - miniserver-bp

**Host**: miniserver-bp (10.17.1.40)
**Instance**: Percaival
**Port**: 18789
**Management**: docker-compose (not oci-containers)
**Version**: latest (npm)
**Updated**: 2026-02-19

---

## Current Status

| Component    | Status       | Notes                                                       |
| ------------ | ------------ | ----------------------------------------------------------- |
| Container    | ✅ Running   | Docker, `--network=host`                                    |
| Telegram     | ✅ Connected | @percaival_bot                                              |
| gog (Google) | ✅ Working   | percy.ai@bytepoets.com                                      |
| m365-email   | ✅ Working   | Percy-AI-miniserver-bp (Azure AD)                           |
| weather      | ✅ Ready     | Bundled skill                                               |
| healthcheck  | ✅ Ready     | Bundled skill                                               |
| GitHub       | ✅ Ready     | bytepoets-percyai                                           |
| Mattermost   | ⏳ Pending   | mattermost.bytepoets.com (installed from bundled extension) |

## Identities

| Service   | Account                | Purpose                      |
| --------- | ---------------------- | ---------------------------- |
| Google    | percy.ai@bytepoets.com | Gmail, Calendar, Drive, Docs |
| Microsoft | percy.ai@bytepoets.com | Email (Exchange)             |
| GitHub    | @bytepoets-percyai     | Code, issues, actions        |

## Available Skills

OpenClaw loads skills from three layers: bundled (npm package), managed (`~/.openclaw/skills`), and workspace (`<workspace>/skills`).

```bash
# List all eligible skills
docker exec openclaw-percaival openclaw skills list
```

### Bundled (ship with npm package, ~50 total)

Key active skills for Percaival:

| Skill       | Description                                                       | Requirements              |
| ----------- | ----------------------------------------------------------------- | ------------------------- |
| gog         | Google Workspace (Gmail, Calendar, Drive, Contacts, Sheets, Docs) | gogcli binary (installed) |
| weather     | Current weather and forecasts                                     | —                         |
| healthcheck | Host security hardening and risk-tolerance                        | —                         |

Other bundled skills are available but may need binaries or API keys. Enable/disable via `openclaw.json` (`skills.entries.<name>.enabled`).

### Workspace Skills (user-installed)

| Skill                  | Description                  | Location                                   |
| ---------------------- | ---------------------------- | ------------------------------------------ |
| m365-email             | Read/send email via M365 CLI | `workspace/skills/m365-email/`             |
| openrouter-free-models | Find free LLMs on OpenRouter | `workspace/skills/openrouter-free-models/` |

Installed manually. Use ClawHub CLI or manual git-clone for more — see "Adding Skills" below.

## Workspace Git Workflow

### Overview

Percy's workspace (`/home/node/.openclaw/workspace/`) is version-controlled via `bytepoets-mba/oc-workspace-percy` (private). Percy pushes via `@bytepoets-percyai`. Markus edits locally in VSCodium.

| Component        | Repo                               | GitHub account       | Local clone                 |
| ---------------- | ---------------------------------- | -------------------- | --------------------------- |
| Nix infra config | `markus-barta/nixcfg`              | `@markus-barta`      | `~/Code/nixcfg`             |
| Percy workspace  | `bytepoets-mba/oc-workspace-percy` | `@bytepoets-percyai` | `~/Code/oc-workspace-percy` |

### Flows

**Percy writes**:

1. Percy edits workspace files during conversation
2. Percy decides when to `git add/commit/push`
3. Daily auto-push safety net catches uncommitted changes (background loop in entrypoint)
4. Markus sees changes via `git pull` in local clone

**Markus writes**:

1. Markus edits in VSCodium
2. Commits + pushes to GitHub
3. Percy picks up changes via `just percy-pull-workspace` or on container restart

### Just Recipes (from mba-imac-work or miniserver-bp)

```bash
just percy-stop              # stop container process
just percy-start             # start container process
just percy-pull-workspace    # git pull inside running container
just percy-rebuild           # rebuild + recreate container
just percy-status            # container status + recent logs
```

**Note:** `percy-rebuild` dauert ca. 15 Minuten (pip installiert pymupdf4llm, pdfplumber — ca. 30MB Python-Pakete). Geduld beim ersten Rebuild nach Dockerfile-Änderungen.

### Container Git Setup

The container's entrypoint:

- Clones workspace repo on first boot (using PAT from agenix secret)
- Pulls latest on subsequent boots (`git pull --ff-only`)
- Configures git identity: `Percy AI <bytepoets-percyai@users.noreply.github.com>`
- Starts daily auto-push background loop (`sleep 86400` cycle)

### PAT Details

- Secret: `miniserver-bp-github-pat.age`
- Account: `@bytepoets-percyai`
- Scopes: `repo`
- Format in secret: `GITHUB_PAT=<token>` (entrypoint strips prefix)

---

## Operational Commands

### Check Status

```bash
# Container status (via docker compose)
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose ps

# Or via docker directly
docker ps | grep openclaw

# View logs
docker compose logs -f openclaw-percaival
# Or: docker logs -f openclaw-percaival

# Gateway health
curl http://10.17.1.40:18789/health
```

### Restart

```bash
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose restart openclaw-percaival
```

### Force Recreate (fresh boot)

```bash
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose down
docker compose up -d --force-recreate
# Or: docker compose up -d --build --force-recreate (rebuild image too)
```

### Stop

```bash
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose stop openclaw-percaival
# Later: docker compose start openclaw-percaival
```

### View Config

```bash
# Current config
cat /var/lib/openclaw-percaival/data/openclaw.json | jq

# Gateway token
docker exec openclaw-percaival openclaw dashboard --no-open
```

### Edit Config

Config is **git-managed** at `hosts/miniserver-bp/docker/openclaw-percaival/openclaw.json`.
The entrypoint copies it into the data volume on every boot (with timestamped backup).

```bash
# Edit in nixcfg repo, commit, push, then:
cd ~/Code/nixcfg && git pull
cd hosts/miniserver-bp/docker
docker compose restart openclaw-percaival
# Entrypoint backs up old config and deploys the new one
```

**Do NOT edit `/var/lib/openclaw-percaival/data/openclaw.json` directly** -- it will be overwritten on next restart.

### Update OpenClaw (duration ~3-5min)

```bash
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose build --no-cache openclaw-percaival
docker compose up -d openclaw-percaival
```

## Telegram Operations

### Pairing

```bash
# List pending pairings
docker exec -it openclaw-percaival openclaw pairing list telegram

# Approve pairing
docker exec -it openclaw-percaival openclaw pairing approve telegram <CODE>
```

### Check Channel Status

```bash
docker exec openclaw-percaival openclaw channels list
```

## gog (Google Workspace)

### Verify Auth

```bash
docker exec openclaw-percaival gog auth list
```

Output:

```
percy.ai@bytepoets.com	default	calendar,chat,classroom,contacts,docs,drive,gmail,people,sheets,tasks	2026-02-12T14:01:52Z	oauth
```

### What gog Provides

- **Gmail**: Read, send, search emails
- **Calendar**: List, create, update events
- **Drive**: Browse, upload, download files
- **Contacts**: Search contacts
- **Sheets/Docs**: Read documents

### Re-authenticate (headless server via SSH port forward)

This is needed after gogcli upgrades or if the OAuth refresh token expires.

**Terminal 1** (on msbp -- start auth, note the port):

```bash
docker exec -it openclaw-percaival gog auth login
# Output: "Opening accounts manager in browser..."
# "If the browser doesn't open, visit: http://127.0.0.1:<PORT>"
# Note the PORT number (random each time, e.g. 38689)
```

**Terminal 2** (from your Mac -- SSH port forward):

```bash
# Replace <PORT> with the port from terminal 1
ssh -L <PORT>:127.0.0.1:<PORT> -p 2222 mba@msbp
```

**Browser** (on your Mac): Open `http://127.0.0.1:<PORT>`, complete Google OAuth flow, close tab when done.

See also: [legacy/OPENCLAW-DOCKER-SETUP-oci-containers.md](./legacy/OPENCLAW-DOCKER-SETUP-oci-containers.md) - gogcli setup section (archived)

### Keyring Password

The gog keyring password is stored in agenix:

- Secret: `miniserver-bp-gogcli-keyring-password.age`
- Format in secret: `GOG_KEYRING_PASSWORD=<password>`
- Injected via NixOS config to container environment

## M365 Email (Microsoft 365)

### Identity

- **Azure AD app**: `Percy-AI-miniserver-bp`
- **Auth**: Client credentials grant (`--authType secret`), fully headless
- **Mailbox**: `percy.ai@bytepoets.com`
- **Permissions**: Mail.Read, Mail.ReadWrite, Mail.Send (application-level, admin-consented)
- **Constraint**: Internal only (@bytepoets.com) — enforced by Exchange transport rule

### Verify Auth

```bash
docker exec openclaw-percaival m365 status
```

Expected: `connectedAs: Percy-AI-miniserver-bp`

### Re-login (if session expired or permissions changed)

Sessions can expire after container rebuilds or m365 CLI upgrades.
Unlike gog, this is fully headless (client credentials, no browser needed).

**Also required after Azure permission changes** — the cached OAuth token
contains the old scopes. A re-login forces a fresh token with updated permissions.
Without re-login, new permissions return 403 until the old token expires (~1 hour).

```bash
# Check status first
docker exec openclaw-percaival m365 status
# If "Logged out" or after permission changes, re-login:
docker exec openclaw-percaival sh -c \
  'm365 login --authType secret \
    --appId "$(cat /run/secrets/m365-client-id)" \
    --tenant "$(cat /run/secrets/m365-tenant-id)" \
    --secret "$(cat /run/secrets/m365-client-secret)"'
# Verify: should show "connectedAs: Percy-AI-miniserver-bp"
docker exec openclaw-percaival m365 status
```

### Test Commands

```bash
# List inbox
docker exec openclaw-percaival m365 outlook message list \
  --folderName inbox --userName percy.ai@bytepoets.com -o json

# Send test email
docker exec openclaw-percaival m365 outlook mail send \
  --to markus.barta@bytepoets.com --subject "Percy test" \
  --bodyContents "Test from miniserver-bp" --sender percy.ai@bytepoets.com
```

### Exchange Transport Rule (hard enforcement)

| Setting       | Value                                                                          |
| ------------- | ------------------------------------------------------------------------------ |
| **Name**      | `Block percy.ai external sends`                                                |
| **Condition** | Sender is `percy.ai@bytepoets.com` AND recipient is outside organization       |
| **Action**    | Reject with: "Percy AI is restricted to internal emails only (@bytepoets.com)" |
| **Mode**      | Enforce                                                                        |
| **Severity**  | High                                                                           |
| **Priority**  | 1                                                                              |

This is the hard security boundary -- even if prompt injection bypasses the skill-level restriction, Exchange blocks the email at the transport layer.

Managed in: **Exchange Admin Center > Mail flow > Rules**

### Secrets (agenix)

| Secret                                 | Content        |
| -------------------------------------- | -------------- |
| `miniserver-bp-m365-client-id.age`     | Application ID |
| `miniserver-bp-m365-tenant-id.age`     | Directory ID   |
| `miniserver-bp-m365-client-secret.age` | Client secret  |

### Skill

Custom workspace skill at `workspace/skills/m365-email/SKILL.md`. Teaches Percy to use `m365` CLI for reading inbox, getting messages, sending internal emails, and downloading attachments via Graph API.

**Security layers in the skill:**

- Anti-prompt-injection rules (treats email body as untrusted data, never as instructions)
- Domain restriction (only @bytepoets.com recipients)
- Identity enforcement (always sends as percy.ai@bytepoets.com)

### Graph API Write Operations (move, update)

The `m365 request` command requires `--body` + `--content-type` for POST/PATCH.
Using `--data` instead of `--body` causes 400 errors.

```bash
# Move message to folder
docker exec openclaw-percaival m365 request \
  --url "https://graph.microsoft.com/v1.0/users/percy.ai@bytepoets.com/messages/<msg-id>/move" \
  --method post \
  --body '{"destinationId":"<folder-id>"}' \
  --content-type 'application/json'

# Mark message as read
docker exec openclaw-percaival m365 request \
  --url "https://graph.microsoft.com/v1.0/users/percy.ai@bytepoets.com/messages/<msg-id>" \
  --method patch \
  --body '{"isRead":true}' \
  --content-type 'application/json'

# List mail folders (get folder IDs)
docker exec openclaw-percaival m365 request \
  --url "https://graph.microsoft.com/v1.0/users/percy.ai@bytepoets.com/mailFolders/inbox/childFolders" \
  --method get
```

**Common pitfalls:**

- `--data` flag → 400 error. Always use `--body` + `--content-type 'application/json'`
- 403 after adding permissions in Azure → re-login needed (cached token, see above)
- `m365 outlook message move` may not exist; use `m365 request` with Graph API `/move` endpoint

### Attachments

The `m365 outlook message get` command does NOT include attachment content. Use `m365 request` with Graph API:

```bash
# List attachments
docker exec openclaw-percaival m365 request \
  --url "https://graph.microsoft.com/v1.0/users/percy.ai@bytepoets.com/messages/<msg-id>/attachments?\$select=id,name,contentType,size" \
  --method get -o json

# Download attachment (base64)
docker exec openclaw-percaival m365 request \
  --url "https://graph.microsoft.com/v1.0/users/percy.ai@bytepoets.com/messages/<msg-id>/attachments/<att-id>" \
  --method get -o json --query "contentBytes" | tr -d '"' | base64 -d > /tmp/filename
```

---

## Adding a New Channel Plugin + Secret

When integrating a new channel (e.g., Mattermost, Slack) that requires a bot token or API key, four files need updating plus an agenix encrypt step.

### Step-by-step

**1. Register the secret in `secrets/secrets.nix`:**

Add an entry under the miniserver-bp section:

```nix
# <Channel name> bot token for OpenClaw Percaival
# Format: Plain text token (no KEY=VALUE)
# Edit: agenix -e secrets/miniserver-bp-<channel>-bot-token.age
"miniserver-bp-<channel>-bot-token.age".publicKeys = markus ++ miniserver-bp;
```

**2. Declare the secret in `hosts/miniserver-bp/configuration.nix`:**

Add under the agenix secrets block:

```nix
age.secrets.miniserver-bp-<channel>-bot-token = {
  file = ../../secrets/miniserver-bp-<channel>-bot-token.age;
  mode = "444";
};
```

If the activation script seeds `openclaw.json` on first boot, also add the channel there:

```json
"channels": {
  "<channel>": { "enabled": true, "dmPolicy": "pairing" }
}
```

**3. Mount + export in `hosts/miniserver-bp/docker/docker-compose.yml`:**

Add volume mount:

```yaml
- /run/agenix/miniserver-bp-<channel>-bot-token:/run/secrets/<channel>-bot-token:ro
```

Add env var export in the entrypoint command block:

```bash
export <CHANNEL>_BOT_TOKEN=$$(cat /run/secrets/<channel>-bot-token)
```

**4. Install the plugin in `hosts/miniserver-bp/docker/openclaw-percaival/Dockerfile`:**

```dockerfile
RUN openclaw plugins install @openclaw/<channel>
```

**5. Create the encrypted secret:**

```bash
agenix -e secrets/miniserver-bp-<channel>-bot-token.age
# Enter the plain text token, save, exit
```

**6. Deploy:**

```bash
# On miniserver-bp (or via SSH):
cd ~/Code/nixcfg && git pull
sudo nixos-rebuild switch --flake .#miniserver-bp

# Rebuild container (plugin added to Dockerfile):
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose build --no-cache openclaw-percaival
docker compose up -d --force-recreate openclaw-percaival
```

**7. Verify:**

```bash
# Check plugin loaded
docker logs openclaw-percaival 2>&1 | grep -i <channel>

# Check env var is set
docker exec openclaw-percaival sh -c 'echo $<CHANNEL>_BOT_TOKEN | head -c4'
```

### Files checklist

| File                                                          | What to add                          |
| ------------------------------------------------------------- | ------------------------------------ |
| `secrets/secrets.nix`                                         | `.age` entry with `publicKeys`       |
| `hosts/miniserver-bp/configuration.nix`                       | `age.secrets.*` block (mode 444)     |
| `hosts/miniserver-bp/docker/docker-compose.yml`               | Volume mount + env var export        |
| `hosts/miniserver-bp/docker/openclaw-percaival/openclaw.json` | Channel config under `channels.<id>` |
| `hosts/miniserver-bp/docker/openclaw-percaival/Dockerfile`    | Only if new system packages needed   |

After all files are committed and pushed, run `agenix -e` locally, then deploy on the host.

---

## Adding Skills

Skills are not managed via Nix — they live in the container's persistent volume. The recommended approach is **ClawHub CLI**; manual git-clone is the fallback.

### Via ClawHub (recommended)

```bash
# Search the registry
docker exec -it openclaw-percaival clawhub search "calendar"

# Install into workspace/skills/
docker exec -it openclaw-percaival clawhub install <skill-slug>

# Update all installed skills
docker exec -it openclaw-percaival clawhub update --all

# List installed (tracks via .clawhub/lock.json)
docker exec -it openclaw-percaival clawhub list
```

If `clawhub` is not in the container, install it first:

```bash
docker exec -it openclaw-percaival npm install -g clawhub
```

### Via git-clone (fallback, for skills not on ClawHub)

```bash
ssh -p 2222 mba@10.17.1.40

sudo mkdir -p /var/lib/openclaw-percaival/data/workspace/skills
sudo chown -R 1000:1000 /var/lib/openclaw-percaival/data/workspace

cd /var/lib/openclaw-percaival/data/workspace/skills
sudo git clone https://github.com/example/skill-name my-skill

cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose restart openclaw-percaival
```

### Find Skills

- ClawHub registry: https://clawhub.ai
- Search: `clawhub search <keyword>`
- Docs: https://docs.openclaw.ai/tools/clawhub

## Multi-Agent

One gateway = multiple agents. No separate containers needed. Each agent gets isolated workspace, identity, sessions, auth, and memory. Sharing between agents uses config-based mechanisms (NOT symlinks — memory search ignores them).

**Isolation**: workspace, sessions, memory, auth — all per-agent by default.
**Sharing**: `skills.load.extraDirs` (skills), `memorySearch.extraPaths` (knowledge), global config (API keys), `tools.agentToAgent` (cross-agent messaging).
**Routing**: `bindings[]` in `openclaw.json` routes channels/peers to agents.

**Current state**: single-agent (Percaival, `agentId: "main"`). Multi-agent = config change only.

### List agents

```bash
docker exec openclaw-percaival openclaw agents list --bindings
```

### Add agent (quick steps)

1. Create workspace dir on host
2. Add to `agents.list[]` + `bindings[]` in `openclaw.json`
3. Add bot token if new Telegram bot (via agenix)
4. `docker compose restart openclaw-percaival`

---

## Files Reference

| What                    | Location                                                                      |
| ----------------------- | ----------------------------------------------------------------------------- |
| docker-compose.yml      | `hosts/miniserver-bp/docker/docker-compose.yml`                               |
| Dockerfile              | `hosts/miniserver-bp/docker/openclaw-percaival/Dockerfile`                    |
| NixOS config            | `hosts/miniserver-bp/configuration.nix`                                       |
| Config (git, canonical) | `hosts/miniserver-bp/docker/openclaw-percaival/openclaw.json`                 |
| Config (runtime copy)   | `/var/lib/openclaw-percaival/data/openclaw.json`                              |
| Workspace               | `/var/lib/openclaw-percaival/data/workspace/`                                 |
| M365 skill              | `/var/lib/openclaw-percaival/data/workspace/skills/m365-email/`               |
| OpenRouter skill        | `/var/lib/openclaw-percaival/data/workspace/skills/openrouter-free-models/`   |
| Secrets (agenix)        | `secrets/miniserver-bp-openclaw-*.age` (telegram, gateway, openrouter, brave) |
| gogcli keyring (agenix) | `secrets/miniserver-bp-gogcli-keyring-password.age`                           |
| M365 secrets (agenix)   | `secrets/miniserver-bp-m365-{client-id,tenant-id,client-secret}.age`          |
| Container logs          | `docker compose logs openclaw-percaival`                                      |
| Gateway log             | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (in container)                        |
| gogcli config           | `/var/lib/openclaw-percaival/gogcli/`                                         |

## Access

| Service    | URL                      |
| ---------- | ------------------------ |
| Control UI | http://10.17.1.40:18789/ |
| Telegram   | @percaival_bot           |

## Git vs Host State

**What goes in git (workspace repo):**

The workspace (`/home/node/.openclaw/workspace/`) is version-controlled in a separate git repo (`bytepoets-mba/oc-workspace-percy`). This includes:

- `skills/` - Skill definitions
- `memory/` - Agent's learned knowledge
- `IDENTITY.md` - Agent identity
- `HEARTBEAT.md` - Agent self-awareness
- `workbench/` - Working files
- `AGENTS.md` - Git workflow instructions

**What stays in `/var/lib/` (NOT in git):**

All other files in `/var/lib/openclaw-percaival/` are runtime state and never go into git:

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

## Related Documentation

- [legacy/OPENCLAW-DOCKER-SETUP-oci-containers.md](./legacy/OPENCLAW-DOCKER-SETUP-oci-containers.md) - Original oci-containers setup (archived 2026-02-15)
- Backlog: `hosts/miniserver-bp/docs/backlog/`
- Migration: `+pm/backlog/msbp/P40--3c1b0d8--migrate-msbp-openclaw-to-compose.md`

## Architecture

**Management**: docker-compose (not NixOS oci-containers)

```
docker-compose.yml → Docker → node:22-bookworm-slim + openclaw@latest
                                ↓
                       /home/node/.openclaw (volume mount)
                                ↓
                       /var/lib/openclaw-percaival/data (host)
```

- Docker Compose manages container lifecycle
- Image built from `docker/openclaw-percaival/Dockerfile`
- Config + data persisted at `/var/lib/openclaw-percaival/data/`
- Secrets injected via env vars from agenix-mounted files (no plaintext in openclaw.json)
- NixOS activation script seeds dirs + openclaw.json template on first boot

### Secret Handling (2026-02-15 update)

All secrets now use env var substitution pattern:

1. **Agenix** decrypts secrets to `/run/agenix/miniserver-bp-openclaw-*`
2. **Compose** mounts secrets as ro volumes to `/run/secrets/*`
3. **Entrypoint** reads secrets into env vars (`TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, etc.)
4. **openclaw.json** references via `${ENV_VAR}` (no plaintext tokens)

This pattern matches Merlin (hsb0) for consistency.

---

## Investigation Log: Docker Bridge vs Loopback

This section documents the pairing issue we hit and what we tried.

### Problem

With default Docker bridge networking, the embedded agent connects to the gateway via the container's bridge IP (`ws://172.17.0.3:18789`). Gateway classifies this as external → enforces device pairing → cron, CLI, and internal tools all fail:

```
[tools] cron failed: gateway closed (1008): pairing required
Gateway target: ws://172.17.0.3:18789
Source: local lan 172.17.0.3
```

### What did NOT work

| Attempt                                                | Why it failed                                               |
| ------------------------------------------------------ | ----------------------------------------------------------- |
| `gateway.controlUi.allowInsecureAuth: true`            | Only affects Control UI, not gateway WS auth                |
| `gateway.controlUi.dangerouslyDisableDeviceAuth: true` | Only affects Control UI                                     |
| `gateway.trustedProxies: ["172.17.0.0/16"]`            | For forwarded headers, not auth bypass                      |
| `OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789` env var    | This env var doesn't exist — OpenClaw ignores it            |
| `openclaw devices approve`                             | Chicken-and-egg: CLI itself needs gateway access to approve |
| Official repo Dockerfile / `docker-setup.sh`           | Same gateway auth logic, doesn't change loopback behavior   |
| `--network=host` + `bind=lan`                          | Agent still connects via host LAN IP (10.17.1.40)           |
| `--network=host` + `bind=auto` for CLI RPC             | Loopback works but CLI RPC still requires pairing           |

### What works

**`--network=host` + `bind=lan`** — container shares host network stack. The in-process agent runtime (cron, Telegram, tools) works because it doesn't go through the RPC pairing layer. `bind=lan` keeps the Control UI accessible from the office LAN.

**Remaining quirk**: CLI RPC commands (`openclaw devices list`, `openclaw gateway status`) still fail with "pairing required" even on loopback. This appears to be a separate pairing layer for WebSocket RPC that is enforced regardless of source IP. The `openclaw doctor` command works because it reads state directly. This doesn't affect actual agent functionality — it's cosmetic.

### m365 CLI "update check failed" Warning

Every `m365` command prints this warning:

```
┌────────────────────────────────────────────────────────┐
│       @pnp/cli-microsoft365 update check failed        │
│ sudo chown -R $USER:$(id -gn $USER) /home/node/.config │
└────────────────────────────────────────────────────────┘
```

**This is harmless.** The m365 CLI tries to write update-check metadata to
`/home/node/.config/cli-microsoft365` and fails on permissions. The actual CLI
works fine — auth, queries, and write operations all succeed. Do NOT try to
fix this with `sudo` (not installed in container) or `chown` (no permission).
Ignore it.

### Pairing architecture

OpenClaw has two distinct connection paths:

1. **In-process agent runtime** — the embedded agent, cron scheduler, and channel connectors (Telegram, etc.) run inside the gateway process. Not subject to device pairing. This is why cron and Telegram work.

2. **CLI RPC commands** — `openclaw devices list`, `openclaw gateway status`, etc. connect via WebSocket RPC. This path enforces device pairing even on loopback. `openclaw doctor` is an exception (reads state directly, no RPC).
