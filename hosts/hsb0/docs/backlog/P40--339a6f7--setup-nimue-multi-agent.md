# setup-nimue-multi-agent

**Host**: hsb0
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-21

---

## Problem

A second OpenClaw agent ("Nimue") needs to be added to `hsb0` alongside "Merlin". They need distinct personalities, Telegram bots, GitHub identities, and isolated state — but must share API keys (OpenRouter, Brave, Home Assistant) and communicate with each other in real-time.

OpenClaw natively supports Multi-Agent Routing within a single Gateway process (`agents.list` + `bindings` + `tools.agentToAgent`). Using two containers would break native `sessions_send` communication and duplicate overhead.

## Solution

Refactor the existing single-agent `openclaw-merlin` container into a multi-agent `openclaw-gateway` container running both Merlin and Nimue side-by-side.

**Architecture after migration:**

```
┌─────────────────────────────────────────────────────────────────┐
│ Docker: openclaw-gateway (single container, network=host)       │
│                                                                 │
│  openclaw gateway --port 18789                                  │
│  ├── Agent: merlin                                              │
│  │   ├── workspace: /home/node/.openclaw/workspace-merlin       │
│  │   ├── agentDir:  /home/node/.openclaw/agents/merlin/agent    │
│  │   ├── sessions:  /home/node/.openclaw/agents/merlin/sessions │
│  │   └── Telegram:  @merlin_oc_bot (account: "merlin")          │
│  │                                                              │
│  ├── Agent: nimue                                               │
│  │   ├── workspace: /home/node/.openclaw/workspace-nimue        │
│  │   ├── agentDir:  /home/node/.openclaw/agents/nimue/agent     │
│  │   ├── sessions:  /home/node/.openclaw/agents/nimue/sessions  │
│  │   └── Telegram:  @nimue_oc_bot (account: "nimue")            │
│  │                                                              │
│  └── tools.agentToAgent: enabled (sessions_send)                │
│                                                                 │
│  Shared env: OPENROUTER_API_KEY, BRAVE_API_KEY                  │
│  Per-agent:  TELEGRAM_BOT_TOKEN_MERLIN, TELEGRAM_BOT_TOKEN_NIMUE│
│              GITHUB_PAT_MERLIN, GITHUB_PAT_NIMUE                │
└─────────────────────────────────────────────────────────────────┘
          │                              │
          ▼                              ▼
/var/lib/openclaw-gateway/merlin   /var/lib/openclaw-gateway/nimue
(host volume, persistent)          (host volume, persistent)
```

**DRY Strategy:**

| Resource                  | Shared? | Notes                                                                          |
| ------------------------- | ------- | ------------------------------------------------------------------------------ |
| Docker image/Dockerfile   | SHARED  | One build context: `docker/openclaw-gateway/`                                  |
| OpenRouter API key        | SHARED  | Single agenix secret, single env var                                           |
| Brave Search API key      | SHARED  | Single agenix secret, single env var                                           |
| Home Assistant token      | SHARED  | Single agenix secret, single env var                                           |
| Opus Gateway creds        | SHARED  | Single agenix secret mount                                                     |
| Gateway auth token        | SHARED  | One gateway = one token                                                        |
| Telegram bot token        | UNIQUE  | Each agent = own BotFather bot                                                 |
| GitHub account + PAT      | UNIQUE  | Each agent = own GitHub identity                                               |
| Workspace (git repo)      | UNIQUE  | Each agent = own repo, own clone                                               |
| Agent state (DB/sessions) | UNIQUE  | Isolated via OpenClaw `agents.list` paths                                      |
| vdirsyncer/khal/gogcli    | UNIQUE  | Isolated via explicit `-c` flags in skills (NOT env vars — see Issue 1 note)   |
| iCloud password           | UNIQUE  | Each agent = own Apple ID app-specific password                                |
| gogcli keyring + account  | UNIQUE  | Each agent = own Google account; injected at entrypoint level (NOT docker env) |

---

## Prerequisites (Manual, by Markus)

These steps require human interaction and cannot be automated:

- [ ] **P1: Create Nimue's Telegram bot** via BotFather.
  - Open Telegram → @BotFather → `/newbot` → name it (e.g., "Nimue AI") → save token.
- [ ] **P2: Create Nimue's GitHub account** (e.g., `nimue-ai-mai` or similar).
  - Create account → generate a PAT with `repo` scope → save token.
- [ ] **P3: Create Nimue's workspace repo** on GitHub.
  - Under `markus-barta` org: `oc-workspace-nimue` (private repo).
  - Initialize with a basic `IDENTITY.md` and `AGENTS.md`.
- [ ] **P4: Encrypt new secrets with agenix** (on imac0 or any machine with your SSH key):
  ```bash
  agenix -e secrets/hsb0-nimue-telegram-token.age   # paste Telegram token
  agenix -e secrets/hsb0-nimue-github-pat.age        # paste GitHub PAT
  agenix -e secrets/hsb0-nimue-icloud-password.age   # if she needs Apple Calendar sync
  agenix -e secrets/hsb0-nimue-gogcli-keyring-password.age # if she needs Google integration
  ```

---

## Implementation (Step-by-Step)

### Phase 0: Backup (CRITICAL - Do this FIRST)

**On hsb0 (via SSH):**

```bash
# Create timestamped backup of ALL Merlin state
BACKUP_DIR="/var/lib/openclaw-merlin-backup-$(date +%Y%m%d-%H%M%S)"
sudo cp -a /var/lib/openclaw-merlin "$BACKUP_DIR"
echo "Backup at: $BACKUP_DIR"

# Verify backup
sudo du -sh "$BACKUP_DIR"
sudo ls -la "$BACKUP_DIR/data/openclaw.json"
sudo ls -la "$BACKUP_DIR/data/workspace/.git"
```

**On imac0 (your dev machine):**

```bash
# Pull a local backup of Merlin's state
mkdir -p ~/Desktop/hsb0-backup
scp -r mba@hsb0.lan:/var/lib/openclaw-merlin/ ~/Desktop/hsb0-backup/
```

- [ ] **B0: Backup Merlin state on hsb0** (`/var/lib/openclaw-merlin-backup-*`)
- [ ] **B1: Backup Merlin state to imac0** (`~/Desktop/hsb0-backup/`)
- [ ] **B2: Verify both backups** contain `data/openclaw.json`, `data/workspace/.git`, `data/devices/paired.json`

### Phase 1: Git changes (local, on imac0 in `~/Code/nixcfg`)

#### 1.1 Rename Docker build context

- [ ] Rename `hosts/hsb0/docker/openclaw-merlin/` → `hosts/hsb0/docker/openclaw-gateway/`
  ```bash
  git mv hosts/hsb0/docker/openclaw-merlin hosts/hsb0/docker/openclaw-gateway
  ```

#### 1.2 Update Dockerfile

- [ ] Edit `hosts/hsb0/docker/openclaw-gateway/Dockerfile`:
  - No functional changes needed — the Dockerfile installs `openclaw@latest`, `git`, `jq`, etc. which work for both agents.
  - Update comment at top if present (s/merlin/gateway/).
  - The `mkdir` line needs to create both agent workspace dirs, both config dirs, AND skills must use explicit path flags (not env vars) for isolation:
    ```dockerfile
    RUN ... \
        && mkdir -p /home/node/.openclaw/workspace-merlin /home/node/.openclaw/workspace-nimue \
                    /home/node/.openclaw/agents/merlin/agent /home/node/.openclaw/agents/nimue/agent \
                    /home/node/.openclaw/agents/merlin/sessions /home/node/.openclaw/agents/nimue/sessions \
                    /home/node/.config/merlin/vdirsyncer /home/node/.config/merlin/khal /home/node/.config/merlin/gogcli \
                    /home/node/.config/nimue/vdirsyncer /home/node/.config/nimue/khal /home/node/.config/nimue/gogcli \
        ...
    ```

  > ⚠️ **Issue 1 fix:** `vdirsyncer` reads `VDIRSYNCER_CONFIG` env var — but that's container-global,
  > not per-agent. Do NOT rely on that env var for isolation. Instead, skills must call:
  > `vdirsyncer -c /home/node/.config/merlin/vdirsyncer/config`
  > `khal -c /home/node/.config/merlin/khal/khal.conf`
  > Merlin's existing skills must be updated to these explicit paths after the migration.
  > Nimue's skills should be written this way from the start.

#### 1.3 Rewrite entrypoint.sh

- [ ] Rewrite `hosts/hsb0/docker/openclaw-gateway/entrypoint.sh` to handle multi-agent init via a loop:

  **Key changes from current single-agent entrypoint:**
  - Build `.env` with SHARED keys (OpenRouter, Brave, HASS) + PER-AGENT keys (Telegram, GitHub PAT)
  - Clone/pull EACH agent's workspace repo using the correct PAT and git identity
  - Seed `auth-profiles.json` for EACH agent under their `agentDir`
  - Write per-agent gogcli environment file (GOG_ACCOUNT, GOG_KEYRING_BACKEND, keyring password) — **NOT** from docker-compose env block
  - Run ONE daily auto-push loop per agent workspace (background)
  - Start ONE gateway process (`openclaw gateway --port 18789`)

  > ⚠️ **Issue 2+3+4 fix:** `GOG_ACCOUNT`, `GOG_KEYRING_BACKEND`, and `GOGCLI_KEYRING_PASSWORD`
  > are **container-global** if set in `docker-compose.yml environment:`. With two agents using
  > different Google accounts this would silently conflict. Solution: remove them from compose,
  > write per-agent env files in the entrypoint, and have skills source the correct one.

  **Agent config data structure** (in entrypoint, as shell variables per agent):

  ```sh
  # MERLIN
  AGENT_ID=merlin
  WORKSPACE_REPO=markus-barta/oc-workspace-merlin
  GITHUB_PAT_FILE=/run/secrets/github-pat-merlin
  GIT_NAME="Merlin AI"
  GIT_EMAIL="merlin-ai-mba@users.noreply.github.com"
  WORKSPACE_DIR=/home/node/.openclaw/workspace-merlin
  AGENT_DIR=/home/node/.openclaw/agents/merlin/agent
  CONFIG_DIR=/home/node/.config/merlin
  GOG_ACCOUNT=markus@barta.com
  GOG_KEYRING_PASSWORD_FILE=/run/secrets/gogcli-keyring-password  # Merlin uses existing secret
  ICLOUD_PASSWORD_FILE=/run/agenix/hsb0-openclaw-icloud-password  # Merlin uses existing secret

  # NIMUE
  AGENT_ID=nimue
  WORKSPACE_REPO=markus-barta/oc-workspace-nimue
  GITHUB_PAT_FILE=/run/secrets/github-pat-nimue
  GIT_NAME="Nimue AI"
  GIT_EMAIL="nimue-ai-mai@users.noreply.github.com"
  WORKSPACE_DIR=/home/node/.openclaw/workspace-nimue
  AGENT_DIR=/home/node/.openclaw/agents/nimue/agent
  CONFIG_DIR=/home/node/.config/nimue
  GOG_ACCOUNT=mailina.barta@gmail.com
  GOG_KEYRING_PASSWORD_FILE=/run/secrets/gogcli-keyring-password-nimue
  ICLOUD_PASSWORD_FILE=/run/secrets/icloud-password-nimue
  ```

  Entrypoint writes a per-agent env file: `/home/node/.config/<agentId>/gogcli.env`
  Skills source this file before invoking `gog` or `vdirsyncer`.

#### 1.4 Rewrite openclaw.json

- [ ] Rewrite `hosts/hsb0/docker/openclaw-gateway/openclaw.json` to multi-agent format:

  **Key changes from current config:**
  - Add `agents.list` with entries for `merlin` and `nimue` (each with `id`, `workspace`, `agentDir`, `name`)
  - Set `merlin` as `default: true`
  - Move `channels.telegram` to use `accounts` map with two bot tokens:
    ```json5
    channels: {
      telegram: {
        enabled: true,
        accounts: {
          merlin: {
            botToken: "${TELEGRAM_BOT_TOKEN_MERLIN}",
            dmPolicy: "pairing",
            groupPolicy: "allowlist",
            streamMode: "partial"
          },
          nimue: {
            botToken: "${TELEGRAM_BOT_TOKEN_NIMUE}",
            dmPolicy: "pairing",
            groupPolicy: "allowlist",
            streamMode: "partial"
          }
        }
      }
    }
    ```
  - Add `bindings`:
    ```json5
    bindings: [
      { agentId: "merlin", match: { channel: "telegram", accountId: "merlin" } },
      { agentId: "nimue", match: { channel: "telegram", accountId: "nimue" } }
    ]
    ```
  - Add `tools.agentToAgent`:
    ```json5
    tools: {
      agentToAgent: { enabled: true, allow: ["merlin", "nimue"] },
      web: { search: { enabled: true }, fetch: { enabled: true } }
    }
    ```
  - Keep all existing model config, cron, skills, etc.

#### 1.5 Update docker-compose.yml

- [ ] Replace `openclaw-merlin` service with `openclaw-gateway`:

  **Changes:**
  - Service name: `openclaw-merlin` → `openclaw-gateway`
  - Container name: `openclaw-merlin` → `openclaw-gateway`
  - Build context: `./openclaw-merlin` → `./openclaw-gateway`
  - Config mount: `./openclaw-merlin/openclaw.json` → `./openclaw-gateway/openclaw.json`
  - Volume mounts — restructure from flat to per-agent:

    ```yaml
    volumes:
      # Shared OpenClaw state (gateway-level)
      - /var/lib/openclaw-gateway/data:/home/node/.openclaw:rw

      # Git-managed config
      - ./openclaw-gateway/openclaw.json:/home/node/.openclaw-config/openclaw.json:ro

      # SHARED secrets (both agents use these)
      - /run/agenix/hsb0-openclaw-gateway-token:/run/secrets/gateway-token:ro
      - /run/agenix/hsb0-openclaw-openrouter-key:/run/secrets/openrouter-key:ro
      - /run/agenix/hsb0-openclaw-brave-key:/run/secrets/brave-key:ro
      - /run/agenix/hsb0-openclaw-hass-token:/run/secrets/hass-token:ro
      - /run/agenix/hsb0-openclaw-opus-gateway:/home/node/.openclaw/credentials/opus-gateway.env:ro

      # MERLIN-specific secrets
      - /run/agenix/hsb0-openclaw-telegram-token:/run/secrets/telegram-token-merlin:ro
      - /run/agenix/hsb0-openclaw-github-pat:/run/secrets/github-pat-merlin:ro

      # NIMUE-specific secrets
      - /run/agenix/hsb0-nimue-telegram-token:/run/secrets/telegram-token-nimue:ro
      - /run/agenix/hsb0-nimue-github-pat:/run/secrets/github-pat-nimue:ro
      - /run/agenix/hsb0-nimue-icloud-password:/run/secrets/icloud-password-nimue:ro
      - /run/agenix/hsb0-nimue-gogcli-keyring-password:/run/secrets/gogcli-keyring-password-nimue:ro

      # MERLIN-specific external tool configs
      - /var/lib/openclaw-gateway/merlin-vdirsyncer:/home/node/.config/merlin/vdirsyncer:rw
      - /var/lib/openclaw-gateway/merlin-khal:/home/node/.config/merlin/khal:rw
      - /var/lib/openclaw-gateway/merlin-gogcli:/home/node/.config/merlin/gogcli:rw

      # NIMUE-specific external tool configs
      - /var/lib/openclaw-gateway/nimue-vdirsyncer:/home/node/.config/nimue/vdirsyncer:rw
      - /var/lib/openclaw-gateway/nimue-khal:/home/node/.config/nimue/khal:rw
      - /var/lib/openclaw-gateway/nimue-gogcli:/home/node/.config/nimue/gogcli:rw
    ```

  - Keep: `network_mode: host`, `user: "node"`, `restart: unless-stopped`
  - **REMOVE** `env_file` for gogcli keyring password — move to entrypoint (see 1.3).
  - **REMOVE** `environment.GOG_ACCOUNT` — move to entrypoint per-agent (see 1.3).
  - **REMOVE** `environment.GOG_KEYRING_BACKEND` — also move to entrypoint.
  - Reason: these are container-global env vars; with two agents they would conflict.
    Entrypoint sets them per-agent before starting the background workers.

#### 1.6 Add new secrets to `secrets/secrets.nix`

- [ ] Add after the existing Merlin secrets block:
  ```nix
  # Nimue agent secrets (second agent in openclaw-gateway)
  # Edit: agenix -e secrets/hsb0-nimue-*.age
  "hsb0-nimue-telegram-token.age".publicKeys = markus ++ hsb0;
  # GitHub PAT for @nimue-ai-mai (workspace git push)
  "hsb0-nimue-github-pat.age".publicKeys = markus ++ hsb0;
  "hsb0-nimue-icloud-password.age".publicKeys = markus ++ hsb0;
  "hsb0-nimue-gogcli-keyring-password.age".publicKeys = markus ++ hsb0;
  ```

#### 1.7 Add new agenix declarations to `hosts/hsb0/configuration.nix`

- [ ] Add after the existing `hsb0-openclaw-github-pat` block:

  ```nix
  # Nimue agent secrets
  age.secrets.hsb0-nimue-telegram-token = {
    file = ../../secrets/hsb0-nimue-telegram-token.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-github-pat = {
    file = ../../secrets/hsb0-nimue-github-pat.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-icloud-password = {
    file = ../../secrets/hsb0-nimue-icloud-password.age;
    mode = "444";
  };
  age.secrets.hsb0-nimue-gogcli-keyring-password = {
    file = ../../secrets/hsb0-nimue-gogcli-keyring-password.age;
    mode = "444";
  };
  ```

- [ ] Update the activation script (rename + add new dirs):

  ```nix
  system.activationScripts.openclaw-gateway = ''
    # Migrate old Merlin data if this is the first run after rename
    if [ -d /var/lib/openclaw-merlin ] && [ ! -d /var/lib/openclaw-gateway ]; then
      echo "[migration] Moving /var/lib/openclaw-merlin → /var/lib/openclaw-gateway/data"
      mkdir -p /var/lib/openclaw-gateway
      mv /var/lib/openclaw-merlin/data /var/lib/openclaw-gateway/data
      mv /var/lib/openclaw-merlin/vdirsyncer /var/lib/openclaw-gateway/merlin-vdirsyncer
      mv /var/lib/openclaw-merlin/khal /var/lib/openclaw-gateway/merlin-khal
      mv /var/lib/openclaw-merlin/gogcli /var/lib/openclaw-gateway/merlin-gogcli
    fi

    # Create base paths
    mkdir -p /var/lib/openclaw-gateway/data/workspace-merlin
    mkdir -p /var/lib/openclaw-gateway/data/workspace-nimue
    mkdir -p /var/lib/openclaw-gateway/data/agents/merlin/agent
    mkdir -p /var/lib/openclaw-gateway/data/agents/nimue/agent
    mkdir -p /var/lib/openclaw-gateway/data/agents/merlin/sessions
    mkdir -p /var/lib/openclaw-gateway/data/agents/nimue/sessions
    mkdir -p /var/lib/openclaw-gateway/data/media/inbound
    mkdir -p /var/lib/openclaw-gateway/data/media/outbound

    # Create external tool paths
    mkdir -p /var/lib/openclaw-gateway/merlin-vdirsyncer
    mkdir -p /var/lib/openclaw-gateway/merlin-khal
    mkdir -p /var/lib/openclaw-gateway/merlin-gogcli
    mkdir -p /var/lib/openclaw-gateway/nimue-vdirsyncer
    mkdir -p /var/lib/openclaw-gateway/nimue-khal
    mkdir -p /var/lib/openclaw-gateway/nimue-gogcli

    chown -R 1000:1000 /var/lib/openclaw-gateway/
  '';
  ```

- [ ] Remove the old `system.activationScripts.openclaw-merlin` block.

- [ ] Update firewall comment: `18789 # OpenClaw Gateway (Merlin + Nimue)`.

#### 1.8 Update justfile

- [ ] Replace the `[merlin]` recipe group with:

  ```just
  # ============================================================================
  # OpenClaw Gateway (hsb0) — Merlin + Nimue multi-agent
  # ============================================================================

  # Rebuild and restart the OpenClaw gateway container
  [group('openclaw')]
  oc-rebuild:
      just _hsb0-run "cd ~/Code/nixcfg/hosts/hsb0/docker && docker compose up -d --build --force-recreate openclaw-gateway"

  # Show gateway container status and recent logs
  [group('openclaw')]
  oc-status:
      just _hsb0-run "docker ps -f name=openclaw-gateway --format 'table {{{{.Status}}\t{{{{.Ports}}' && echo '---' && docker logs openclaw-gateway --tail 30"

  # Stop the OpenClaw gateway
  [group('openclaw')]
  oc-stop:
      just _hsb0-run "cd ~/Code/nixcfg/hosts/hsb0/docker && docker compose stop openclaw-gateway"

  # Start the OpenClaw gateway
  [group('openclaw')]
  oc-start:
      just _hsb0-run "cd ~/Code/nixcfg/hosts/hsb0/docker && docker compose start openclaw-gateway"

  # Pull Merlin's workspace changes into running container
  [group('openclaw')]
  merlin-pull-workspace:
      just _hsb0-run "docker exec openclaw-gateway git -C /home/node/.openclaw/workspace-merlin pull --ff-only"

  # Pull Nimue's workspace changes into running container
  [group('openclaw')]
  nimue-pull-workspace:
      just _hsb0-run "docker exec openclaw-gateway git -C /home/node/.openclaw/workspace-nimue pull --ff-only"
  ```

#### 1.9 Local workspace clone (imac0)

- [ ] Clone Nimue's workspace locally:
  ```bash
  cd ~/Code
  git clone https://github.com/markus-barta/oc-workspace-nimue.git
  ```
- [ ] Add it to the VSCodium workspace file (`nixcfg+agents.code-workspace`).

### Phase 2: Deploy

**Deployment order matters! Follow exactly:**

1. [ ] **Commit and push** all git changes from Phase 1.
2. [ ] **On hsb0** (via SSH or just recipes):
   ```bash
   cd ~/Code/nixcfg
   git pull
   just switch    # deploys new agenix secrets + activation script (creates dirs, migrates data)
   ```
3. [ ] **Verify migration** happened:
   ```bash
   ls -la /var/lib/openclaw-gateway/data/openclaw.json
   ls -la /var/lib/openclaw-gateway/data/workspace-merlin/.git  # should exist if migration ran
   ```
4. [ ] **Stop old container** (if still running under old name):
   ```bash
   cd ~/Code/nixcfg/hosts/hsb0/docker
   docker compose stop openclaw-merlin 2>/dev/null || true
   ```
5. [ ] **Build and start new container**:
   ```bash
   docker compose up -d --build --force-recreate openclaw-gateway
   ```
6. [ ] **Watch logs**:
   ```bash
   docker logs -f openclaw-gateway
   ```
   Expected: Merlin's workspace cloned/pulled, Nimue's workspace cloned, both Telegram bots connected, gateway listening on 18789.

### Phase 3: Verify

- [ ] **V1: Gateway health**: `curl http://192.168.1.99:18789/health`
- [ ] **V2: Merlin responds on Telegram** — send a message to `@merlin_oc_bot`
- [ ] **V3: Nimue responds on Telegram** — send a message to `@nimue_oc_bot` (name TBD)
- [ ] **V4: Pair BOTH agents** (known first-boot pairing issue — expect it for both):

  ```bash
  # Check Merlin (should already be paired from before migration — verify)
  docker exec openclaw-gateway cat /home/node/.openclaw/agents/merlin/agent/devices/paired.json
  docker exec openclaw-gateway cat /home/node/.openclaw/agents/merlin/agent/devices/pending.json

  # Check Nimue (will almost certainly need manual pairing on first boot)
  docker exec openclaw-gateway cat /home/node/.openclaw/agents/nimue/agent/devices/pending.json
  ```

  If `pending.json` is non-empty and `paired.json` is missing/empty for either agent:

  ```bash
  # Get deviceId + publicKey from pending.json, then write paired.json
  # (see OPENCLAW-RUNBOOK.md "pairing required" troubleshooting for exact command)
  # Restart after fixing both:
  docker restart openclaw-gateway
  ```

  > ⚠️ **Issue 5 note:** After migration Merlin's `paired.json` lives at the new path
  > (`agents/merlin/agent/devices/paired.json`). If the migration script moved his data
  > correctly it should be populated. Verify before assuming pairing is needed.

- [ ] **V5: Agent-to-agent comm**: Ask Merlin on Telegram: "Send a message to Nimue saying hello"
- [ ] **V6: Merlin's state intact**: Check Merlin remembers past conversations, skills work, cron jobs fire
- [ ] **V7: Git push from both agents**: Trigger a workspace change in each, verify commits appear under correct GitHub accounts

### Phase 4: Cleanup & Documentation

- [ ] **D1: Update Merlin's existing skills** to use explicit `-c` paths:
  - `calendar` skill: `vdirsyncer -c /home/node/.config/merlin/vdirsyncer/config`
  - `calendar` skill: `khal -c /home/node/.config/merlin/khal/khal.conf`
  - Any skill calling `gog` must source `/home/node/.config/merlin/gogcli.env` first
  - Verify Nimue's new skills are written with `/home/node/.config/nimue/...` from the start
- [ ] **D2: Update `OPENCLAW-RUNBOOK.md`** — reflect multi-agent architecture, new paths, new commands
- [ ] **D3: Update `hsb0/README.md`** — add Nimue to features table, update firewall comment
- [ ] **D4: Update workspace git workflow section** in runbook (add Nimue row to table)
- [ ] **D5: Keep backup for 30 days** then remove:
  - hsb0: `/var/lib/openclaw-merlin-backup-*`
  - imac0: `~/Desktop/hsb0-backup/`

---

## Rollback Plan

If anything goes wrong after Phase 2:

```bash
# 1. Stop new container
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose stop openclaw-gateway

# 2. Restore Merlin's state from backup
sudo cp -a /var/lib/openclaw-merlin-backup-*/. /var/lib/openclaw-merlin/

# 3. Revert git changes
cd ~/Code/nixcfg
git revert HEAD  # or git checkout main

# 4. Rebuild old config
just switch
docker compose up -d --build --force-recreate openclaw-merlin

# 5. Verify Merlin is back
docker logs -f openclaw-merlin
```

---

## Acceptance Criteria

- [ ] Single `openclaw-gateway` container runs both agents.
- [ ] Merlin responds on his existing Telegram bot with full state/memory preserved.
- [ ] Nimue responds on her own Telegram bot.
- [ ] Agent state (DB/sessions/workspace) is fully isolated.
- [ ] Agents can communicate in real-time using `sessions_send`.
- [ ] Commits from Nimue appear under her distinct GitHub account.
- [ ] `just oc-rebuild`, `just oc-status`, `just merlin-pull-workspace`, `just nimue-pull-workspace` all work.
- [ ] OPENCLAW-RUNBOOK.md and README.md are updated.
- [ ] Backups verified and retention period set.

---

## Files Modified (Complete List)

| File                                               | Change                                                           |
| -------------------------------------------------- | ---------------------------------------------------------------- |
| `hosts/hsb0/docker/openclaw-merlin/`               | **Renamed** → `openclaw-gateway/`                                |
| `hosts/hsb0/docker/openclaw-gateway/Dockerfile`    | Updated dirs for multi-agent                                     |
| `hosts/hsb0/docker/openclaw-gateway/entrypoint.sh` | **Rewritten** for multi-agent loop                               |
| `hosts/hsb0/docker/openclaw-gateway/openclaw.json` | **Rewritten** with `agents.list`, `bindings`, `agentToAgent`     |
| `hosts/hsb0/docker/docker-compose.yml`             | Service rename + new volume mounts                               |
| `hosts/hsb0/configuration.nix`                     | New agenix secrets, activation script rename + migration logic   |
| `secrets/secrets.nix`                              | New `hsb0-nimue-telegram-token.age`, `hsb0-nimue-github-pat.age` |
| `secrets/hsb0-nimue-telegram-token.age`            | **New** (encrypted)                                              |
| `secrets/hsb0-nimue-github-pat.age`                | **New** (encrypted)                                              |
| `secrets/hsb0-nimue-icloud-password.age`           | **New** (encrypted)                                              |
| `secrets/hsb0-nimue-gogcli-keyring-password.age`   | **New** (encrypted)                                              |
| `justfile`                                         | Replace `[merlin]` group with `[openclaw]` group                 |
| `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`              | Updated for multi-agent                                          |
| `hosts/hsb0/README.md`                             | Add Nimue to features, update firewall comment                   |

## References

- OpenClaw Multi-Agent Routing: `https://docs.openclaw.ai/concepts/multi-agent`
- OpenClaw Session Tools (sessions_send): `https://docs.openclaw.ai/concepts/session-tool`
- OpenClaw Gateway Config Reference: `https://docs.openclaw.ai/gateway/configuration-reference`
- Current Merlin RUNBOOK: `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`
- Percy (sister instance, same patterns): `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md`
