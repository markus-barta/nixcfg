# percy-multi-agent-gateway-james

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-23

---

## Problem

Percy (miniserver-bp) runs as a single-agent OpenClaw gateway (`openclaw-percaival`). A second agent "James" is needed -- Scrum Master, Sales & basic PM tasks for BYTEPOETS. The hsb0 gateway was migrated to multi-agent (Merlin + Nimue) on 2026-02-21. Percy needs the same treatment, plus:

- Shared workspace between Percy and James (BYTEPOETS-specific, separate from home/family shared)
- SSH access for James to miniserver-bp (dedicated user)
- Cron-based shared workspace sync (matching hsb0 pattern)
- Updated config management (model list, agent-to-agent comms, sessions visibility)

## Solution

Refactor `openclaw-percaival` into a multi-agent `openclaw-gateway` container running Percy + James. Follow the proven hsb0 migration pattern (`+pm/done/P40--339a6f7--setup-nimue-multi-agent.md`).

**Architecture after migration:**

```
+-----------------------------------------------------------------+
| Docker: openclaw-gateway (single container, network=host)       |
|                                                                 |
|  openclaw gateway --port 18789                                  |
|  +-- Agent: percy  (default)                                    |
|  |   +-- workspace: /home/node/.openclaw/workspace-percy        |
|  |   +-- agentDir:  /home/node/.openclaw/agents/percy/agent     |
|  |   +-- sessions:  /home/node/.openclaw/agents/percy/sessions  |
|  |   +-- Telegram:  @percaival_bot (account: "percy")           |
|  |   +-- Mattermost: existing binding                           |
|  |                                                              |
|  +-- Agent: james                                               |
|  |   +-- workspace: /home/node/.openclaw/workspace-james        |
|  |   +-- agentDir:  /home/node/.openclaw/agents/james/agent     |
|  |   +-- sessions:  /home/node/.openclaw/agents/james/sessions  |
|  |   +-- Telegram:  @james_bp_bot (account: "james")            |
|  |   +-- Mattermost: own binding                                |
|  |                                                              |
|  +-- tools.agentToAgent: enabled (sessions_send)                |
|                                                                 |
|  Shared env: OPENROUTER_API_KEY, BRAVE_API_KEY                  |
|  Per-agent:  TELEGRAM_BOT_TOKEN_PERCY, TELEGRAM_BOT_TOKEN_JAMES |
|              GITHUB_PAT_PERCY, GITHUB_PAT_JAMES                 |
|              MATTERMOST_BOT_TOKEN (shared or per-agent TBD)     |
+-----------------------------------------------------------------+
          |                              |
          v                              v
/var/lib/openclaw-gateway/data     (shared OpenClaw state)
+-- workspace-percy/               (bytepoets-mba/oc-workspace-percy)
+-- workspace-james/               (bytepoets-mba/oc-workspace-james)
+-- workspace-shared/              (bytepoets-mba/oc-workspace-shared-bp)
```

**DRY Strategy (same as hsb0):**

| Resource                  | Shared? | Notes                                            |
| ------------------------- | ------- | ------------------------------------------------ |
| Docker image/Dockerfile   | SHARED  | One build context: `docker/openclaw-gateway/`    |
| OpenRouter API key        | SHARED  | Single agenix secret, single env var             |
| Brave Search API key      | SHARED  | Single agenix secret, single env var             |
| Gateway auth token        | SHARED  | One gateway = one token                          |
| Telegram bot token        | UNIQUE  | Each agent = own BotFather bot                   |
| Mattermost bot token      | TBD     | May be shared or per-agent depending on MM setup |
| GitHub account + PAT      | UNIQUE  | Each agent = own GitHub identity                 |
| Workspace (git repo)      | UNIQUE  | Each agent = own repo, own clone                 |
| Agent state (DB/sessions) | UNIQUE  | Isolated via OpenClaw `agents.list` paths        |
| Google account            | UNIQUE  | percy.ai@ vs james.ai@bytepoets.com              |
| M365 account              | UNIQUE  | percy.ai@ vs james.ai@bytepoets.com              |
| gogcli keyring + account  | UNIQUE  | Injected at entrypoint level (NOT docker env)    |
| M365 credentials          | UNIQUE  | Each agent = own Azure AD app + client secret    |

---

## Prerequisites (Manual, by Markus)

These steps require human interaction and cannot be automated:

- [ ] **P1: Create James's Telegram bot** via BotFather
  - Open Telegram -> @BotFather -> `/newbot` -> name it (e.g., "James AI") -> save token

- [ ] **P2: Create James's GitHub account** (`bytepoets-jamesai`)
  - Create account -> generate a PAT with `repo` scope -> save token

- [ ] **P3: Create James's workspace repo** on GitHub
  - Under `bytepoets-mba` org: `oc-workspace-james` (private repo)
  - Initialize with `IDENTITY.md`, `AGENTS.md`, `HEARTBEAT.md`

- [ ] **P4: Create BYTEPOETS shared workspace repo** on GitHub
  - Under `bytepoets-mba` org: `oc-workspace-shared-bp` (private repo)
  - Initialize with:
    - `KNOWLEDGEBASE.md` -- BYTEPOETS team context, projects, processes
    - `KB.md` -> symlink to `KNOWLEDGEBASE.md`
    - `FROM-PERCY.md` -- stub: "# From Percy"
    - `FROM-JAMES.md` -- stub: "# From James"
  - Grant read/write to both `bytepoets-percyai` and `bytepoets-jamesai`

- [ ] **P5: Create James's Google account** (`james.ai@bytepoets.com`)
  - Google Workspace admin -> create user -> save credentials

- [ ] **P6: Create James's Azure AD app** (`James-AI-miniserver-bp`)
  - Azure portal -> App registration -> client credentials grant
  - Permissions: Mail.Read, Mail.ReadWrite, Mail.Send (application-level, admin-consented)
  - Add Exchange transport rule: block james.ai external sends (same as Percy)
  - Save: client ID, tenant ID, client secret

- [ ] **P7: Create `james` user on miniserver-bp** (SSH access)
  - Add to NixOS config: user with SSH key auth, appropriate groups
  - Like `merlin` user on hsb1 (wheel + docker groups)

- [ ] **P8: Encrypt new secrets with agenix** (on mba-imac-work or machine with SSH key):
  ```bash
  agenix -e secrets/miniserver-bp-james-telegram-token.age
  agenix -e secrets/miniserver-bp-james-github-pat.age
  agenix -e secrets/miniserver-bp-james-gogcli-keyring-password.age
  agenix -e secrets/miniserver-bp-james-m365-client-id.age
  agenix -e secrets/miniserver-bp-james-m365-tenant-id.age
  agenix -e secrets/miniserver-bp-james-m365-client-secret.age
  agenix -e secrets/miniserver-bp-james-ssh-key.age
  ```

---

## Implementation (Step-by-Step)

### Phase 0: Backup (CRITICAL -- Do this FIRST)

**On miniserver-bp (via SSH):**

```bash
BACKUP_DIR="/var/lib/openclaw-percaival-backup-$(date +%Y%m%d-%H%M%S)"
sudo cp -a /var/lib/openclaw-percaival "$BACKUP_DIR"
echo "Backup at: $BACKUP_DIR"
sudo du -sh "$BACKUP_DIR"
sudo ls -la "$BACKUP_DIR/data/openclaw.json"
```

**On mba-imac-work:**

```bash
mkdir -p ~/Desktop/msbp-backup
scp -r mba@miniserver-bp.local:/var/lib/openclaw-percaival/ ~/Desktop/msbp-backup/
```

- [ ] **B0: Backup Percy state on miniserver-bp**
- [ ] **B1: Backup Percy state to mba-imac-work**
- [ ] **B2: Verify both backups** contain `data/openclaw.json`, `data/workspace/.git`, `data/devices/paired.json`

### Phase 1: Git changes (local, on mba-imac-work in `~/Code/nixcfg`)

#### 1.1 Rename Docker build context

- [ ] Rename `hosts/miniserver-bp/docker/openclaw-percaival/` -> `hosts/miniserver-bp/docker/openclaw-gateway/`
  ```bash
  git mv hosts/miniserver-bp/docker/openclaw-percaival hosts/miniserver-bp/docker/openclaw-gateway
  ```

#### 1.2 Update Dockerfile

- [ ] Edit `hosts/miniserver-bp/docker/openclaw-gateway/Dockerfile`:
  - Add `cron`, `sudo`, `openssh-client` packages (matching hsb0 pattern)
  - Keep Percy-specific packages: `pymupdf4llm`, `pdfplumber`, `poppler-utils`, `gh`
  - Create per-agent dirs:
    ```dockerfile
    RUN ... \
        && mkdir -p /home/node/.openclaw/workspace-percy /home/node/.openclaw/workspace-james \
                    /home/node/.openclaw/workspace-shared \
                    /home/node/.openclaw/agents/percy/agent /home/node/.openclaw/agents/james/agent \
                    /home/node/.openclaw/agents/percy/sessions /home/node/.openclaw/agents/james/sessions \
                    /home/node/.config/percy/gogcli /home/node/.config/james/gogcli \
        ...
    ```
  - Add sudoers entry for cron (matching hsb0):
    ```dockerfile
    RUN echo "node ALL=(ALL) NOPASSWD: /usr/sbin/cron" >> /etc/sudoers
    ```

#### 1.3 Rewrite entrypoint.sh

- [ ] Rewrite `hosts/miniserver-bp/docker/openclaw-gateway/entrypoint.sh` for multi-agent:

  **Changes from current single-agent entrypoint (follow hsb0 pattern):**
  - Read shared secrets + per-agent secrets from `/run/secrets/*`
  - Write `.env` with shared keys + per-agent Telegram/GitHub/Mattermost tokens
  - Add `init_agent()` function (matching hsb0 entrypoint)
  - Call `init_agent` for Percy and James with their respective configs:

    ```sh
    # PERCY
    init_agent \
      "percy" \
      "bytepoets-mba/oc-workspace-percy" \
      "${GITHUB_PAT_PERCY}" \
      "Percy AI" \
      "<numeric>+bytepoets-percyai@users.noreply.github.com" \
      "percy.ai@bytepoets.com" \
      "/run/secrets/gogcli-keyring-password-percy"

    # JAMES
    init_agent \
      "james" \
      "bytepoets-mba/oc-workspace-james" \
      "${GITHUB_PAT_JAMES}" \
      "James AI" \
      "<numeric>+bytepoets-jamesai@users.noreply.github.com" \
      "james.ai@bytepoets.com" \
      "/run/secrets/gogcli-keyring-password-james"
    ```

  - Add shared workspace clone/pull + symlinks (matching hsb0 section 5)
  - Add nightly cron sync (matching hsb0 section 6):
    - Percy: 23:30 -- pull + commit `FROM-PERCY.md` + push
    - James: 23:31 -- pull + commit `FROM-JAMES.md` + push
  - Install SSH key for James -> miniserver-bp access (matching hsb0 Merlin -> hsb1 pattern)
  - Install mattermost plugin (keep from current entrypoint)
  - M365 login for both agents (if client credentials available, headless)
  - Start cron daemon via sudo before final `exec`

  **Percy workspace migration note:** Current workspace is at `/home/node/.openclaw/workspace`.
  Migration needs to move it to `/home/node/.openclaw/workspace-percy`. Handle in activation script
  (Phase 1.7) like hsb0 did for Merlin's data migration.

#### 1.4 Rewrite openclaw.json

- [ ] Rewrite `hosts/miniserver-bp/docker/openclaw-gateway/openclaw.json` to multi-agent:

  **Key changes from current single-agent config:**
  - Percy's `agentId` changes from `"main"` to `"percy"` with `"default": true`
  - Add James to `agents.list`:
    ```json
    {
      "id": "james",
      "name": "James",
      "workspace": "/home/node/.openclaw/workspace-james",
      "agentDir": "/home/node/.openclaw/agents/james/agent",
      "identity": {
        "name": "James",
        "theme": "professional Scrum Master and PM with a calm, structured approach",
        "emoji": "📋"
      },
      "groupChat": {
        "mentionPatterns": ["@James", "James"]
      }
    }
    ```
  - Move `channels.telegram` to `accounts` map (two bot tokens):
    ```json
    "telegram": {
      "enabled": true,
      "accounts": {
        "percy": {
          "botToken": "${TELEGRAM_BOT_TOKEN_PERCY}",
          "dmPolicy": "pairing",
          "groupPolicy": "allowlist",
          "streamMode": "partial"
        },
        "james": {
          "botToken": "${TELEGRAM_BOT_TOKEN_JAMES}",
          "dmPolicy": "pairing",
          "groupPolicy": "allowlist",
          "streamMode": "partial"
        }
      }
    }
    ```
  - Keep Mattermost channel (decide binding: shared or per-agent)
  - Add `bindings`:
    ```json
    "bindings": [
      { "agentId": "percy", "match": { "channel": "telegram", "accountId": "percy" } },
      { "agentId": "james", "match": { "channel": "telegram", "accountId": "james" } }
    ]
    ```
  - Add `tools.agentToAgent` + `tools.sessions.visibility`:
    ```json
    "tools": {
      "agentToAgent": { "enabled": true, "allow": ["percy", "james"] },
      "sessions": { "visibility": "all" },
      "web": { "search": { "enabled": true }, "fetch": { "enabled": true } }
    }
    ```
  - Update model list to match hsb0 (Gemini 3 Flash Preview primary, Kimi K2.5 fallback, expanded model options)

#### 1.5 Update docker-compose.yml

- [ ] Replace `openclaw-percaival` service with `openclaw-gateway`:

  **Changes:**
  - Service name: `openclaw-percaival` -> `openclaw-gateway`
  - Container name: `openclaw-percaival` -> `openclaw-gateway`
  - Build context: `./openclaw-percaival` -> `./openclaw-gateway`
  - Config mount: `./openclaw-percaival/openclaw.json` -> `./openclaw-gateway/openclaw.json`
  - Volume mounts -- restructure from flat to per-agent:

    ```yaml
    volumes:
      # Shared OpenClaw state (gateway-level)
      - /var/lib/openclaw-gateway/data:/home/node/.openclaw:rw

      # Git-managed config
      - ./openclaw-gateway/openclaw.json:/home/node/.openclaw-config/openclaw.json:ro

      # SHARED secrets
      - /run/agenix/miniserver-bp-openclaw-gateway-token:/run/secrets/gateway-token:ro
      - /run/agenix/miniserver-bp-openclaw-openrouter-key:/run/secrets/openrouter-key:ro
      - /run/agenix/miniserver-bp-openclaw-brave-key:/run/secrets/brave-key:ro

      # PERCY-specific secrets
      - /run/agenix/miniserver-bp-openclaw-telegram-token:/run/secrets/telegram-token-percy:ro
      - /run/agenix/miniserver-bp-github-pat:/run/secrets/github-pat-percy:ro
      - /run/agenix/miniserver-bp-gogcli-keyring-password:/run/secrets/gogcli-keyring-password-percy:ro
      - /run/agenix/miniserver-bp-m365-client-id:/run/secrets/m365-client-id-percy:ro
      - /run/agenix/miniserver-bp-m365-tenant-id:/run/secrets/m365-tenant-id-percy:ro
      - /run/agenix/miniserver-bp-m365-client-secret:/run/secrets/m365-client-secret-percy:ro

      # JAMES-specific secrets
      - /run/agenix/miniserver-bp-james-telegram-token:/run/secrets/telegram-token-james:ro
      - /run/agenix/miniserver-bp-james-github-pat:/run/secrets/github-pat-james:ro
      - /run/agenix/miniserver-bp-james-gogcli-keyring-password:/run/secrets/gogcli-keyring-password-james:ro
      - /run/agenix/miniserver-bp-james-m365-client-id:/run/secrets/m365-client-id-james:ro
      - /run/agenix/miniserver-bp-james-m365-tenant-id:/run/secrets/m365-tenant-id-james:ro
      - /run/agenix/miniserver-bp-james-m365-client-secret:/run/secrets/m365-client-secret-james:ro
      - /run/agenix/miniserver-bp-james-ssh-key:/run/secrets/james-ssh-key:ro

      # Per-agent external tool configs
      - /var/lib/openclaw-gateway/percy-gogcli:/home/node/.config/percy/gogcli:rw
      - /var/lib/openclaw-gateway/james-gogcli:/home/node/.config/james/gogcli:rw
    ```

  - **REMOVE** `env_file` for gogcli keyring password -- move to entrypoint
  - **REMOVE** `environment.GOG_ACCOUNT` / `GOG_KEYRING_BACKEND` -- move to entrypoint per-agent
  - Keep: `network_mode: host`, `user: "node"`, `restart: unless-stopped`

#### 1.6 Add new secrets to `secrets/secrets.nix`

- [ ] Add James agent secrets block:
  ```nix
  # James agent secrets (second agent in miniserver-bp openclaw-gateway)
  # Edit: agenix -e secrets/miniserver-bp-james-*.age
  "miniserver-bp-james-telegram-token.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-james-github-pat.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-james-gogcli-keyring-password.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-james-m365-client-id.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-james-m365-tenant-id.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-james-m365-client-secret.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-james-ssh-key.age".publicKeys = markus ++ miniserver-bp;
  ```

#### 1.7 Update `hosts/miniserver-bp/configuration.nix`

- [ ] Add James agenix secret declarations (all `mode = "444"`):

  ```nix
  age.secrets.miniserver-bp-james-telegram-token = {
    file = ../../secrets/miniserver-bp-james-telegram-token.age;
    mode = "444";
  };
  # ... (same pattern for all 7 James secrets)
  ```

- [ ] Add `james` user to NixOS config:

  ```nix
  users.users.james = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      # James AI SSH public key (from agenix-managed key pair)
    ];
  };
  ```

- [ ] Update activation script -- rename + migration + new dirs:

  ```nix
  system.activationScripts.openclaw-gateway = ''
    # Migrate old Percy data if this is the first run after rename
    if [ -d /var/lib/openclaw-percaival ] && [ ! -d /var/lib/openclaw-gateway ]; then
      echo "[migration] Moving /var/lib/openclaw-percaival -> /var/lib/openclaw-gateway"
      mkdir -p /var/lib/openclaw-gateway
      mv /var/lib/openclaw-percaival/data /var/lib/openclaw-gateway/data
      mv /var/lib/openclaw-percaival/gogcli /var/lib/openclaw-gateway/percy-gogcli 2>/dev/null || true
    fi

    # Migrate Percy workspace from flat to per-agent path
    if [ -d /var/lib/openclaw-gateway/data/workspace ] && \
       [ ! -d /var/lib/openclaw-gateway/data/workspace-percy ]; then
      echo "[migration] Moving workspace -> workspace-percy"
      mv /var/lib/openclaw-gateway/data/workspace /var/lib/openclaw-gateway/data/workspace-percy
    fi

    # Migrate Percy agent state from "main" to "percy"
    if [ -d /var/lib/openclaw-gateway/data/agents/main ] && \
       [ ! -d /var/lib/openclaw-gateway/data/agents/percy ]; then
      echo "[migration] Moving agents/main -> agents/percy"
      mv /var/lib/openclaw-gateway/data/agents/main /var/lib/openclaw-gateway/data/agents/percy
    fi

    # Create base paths
    mkdir -p /var/lib/openclaw-gateway/data/workspace-percy
    mkdir -p /var/lib/openclaw-gateway/data/workspace-james
    mkdir -p /var/lib/openclaw-gateway/data/workspace-shared
    mkdir -p /var/lib/openclaw-gateway/data/agents/percy/agent
    mkdir -p /var/lib/openclaw-gateway/data/agents/james/agent
    mkdir -p /var/lib/openclaw-gateway/data/agents/percy/sessions
    mkdir -p /var/lib/openclaw-gateway/data/agents/james/sessions
    mkdir -p /var/lib/openclaw-gateway/data/media/inbound
    mkdir -p /var/lib/openclaw-gateway/data/media/outbound

    # External tool paths
    mkdir -p /var/lib/openclaw-gateway/percy-gogcli
    mkdir -p /var/lib/openclaw-gateway/james-gogcli

    chown -R 1000:1000 /var/lib/openclaw-gateway/
  '';
  ```

- [ ] Remove old `system.activationScripts.openclaw-percaival` block
- [ ] Update firewall comment: `18789 # OpenClaw Gateway (Percy + James)`

#### 1.8 Add shared-sync.sh

- [ ] Create `hosts/miniserver-bp/docker/openclaw-gateway/shared-sync.sh` (matching hsb0 pattern):
  - Takes agent ID as argument
  - Sets git identity per agent
  - Sets remote URL with agent's PAT
  - `git pull --ff-only` -> `git add FROM-<AGENT>.md` -> commit if changed -> push
  - Shared repo: `bytepoets-mba/oc-workspace-shared-bp`

#### 1.9 Update justfile

- [ ] Replace `[percy]` recipe group with `[openclaw-bp]` group:

  ```just
  # OpenClaw Gateway (miniserver-bp) -- Percy + James multi-agent

  [group('openclaw-bp')]
  percy-rebuild:
      just _msbp-run "cd ~/Code/nixcfg/hosts/miniserver-bp/docker && docker compose up -d --build --force-recreate openclaw-gateway"

  [group('openclaw-bp')]
  percy-status:
      just _msbp-run "docker ps -f name=openclaw-gateway ..."

  [group('openclaw-bp')]
  percy-pull-workspace:
      just _msbp-run "docker exec openclaw-gateway git -C /home/node/.openclaw/workspace-percy pull --ff-only"

  [group('openclaw-bp')]
  james-pull-workspace:
      just _msbp-run "docker exec openclaw-gateway git -C /home/node/.openclaw/workspace-james pull --ff-only"
  ```

#### 1.10 Local workspace clones (mba-imac-work)

- [ ] Clone James's workspace locally:
  ```bash
  cd ~/Code && git clone https://github.com/bytepoets-mba/oc-workspace-james.git
  ```
- [ ] Clone BYTEPOETS shared workspace:
  ```bash
  cd ~/Code && git clone https://github.com/bytepoets-mba/oc-workspace-shared-bp.git
  ```
- [ ] Update VSCodium workspace file to include new repos

### Phase 2: Deploy

**Deployment order matters! Follow exactly:**

1. [ ] **Commit and push** all git changes from Phase 1
2. [ ] **On miniserver-bp** (via SSH):
   ```bash
   cd ~/Code/nixcfg
   git pull
   just switch    # deploys new agenix secrets + activation script (creates dirs, migrates data)
   ```
3. [ ] **Verify migration** happened:
   ```bash
   ls -la /var/lib/openclaw-gateway/data/openclaw.json
   ls -la /var/lib/openclaw-gateway/data/workspace-percy/.git
   ls -la /var/lib/openclaw-gateway/data/agents/percy/agent  # migrated from agents/main
   ```
4. [ ] **Stop old container** (if still running under old name):
   ```bash
   cd ~/Code/nixcfg/hosts/miniserver-bp/docker
   docker compose stop openclaw-percaival 2>/dev/null || true
   ```
5. [ ] **Build and start new container** (~15 min due to pip packages):
   ```bash
   docker compose up -d --build --force-recreate openclaw-gateway
   ```
6. [ ] **Watch logs**:
   ```bash
   docker logs -f openclaw-gateway
   ```
   Expected: Percy's workspace pulled, James's workspace cloned, shared workspace cloned,
   both Telegram bots connected, Mattermost connected, gateway listening on 18789.

### Phase 3: Post-deploy setup (Human)

- [ ] **S1: gog auth for James** (headless, needs SSH port forward -- same as Percy pattern):
  ```bash
  # Terminal 1 on miniserver-bp:
  docker exec -it openclaw-gateway sh -c '. /home/node/.env && gog auth login --agent james'
  # Terminal 2 from Mac: ssh -L <PORT>:127.0.0.1:<PORT> mba@miniserver-bp.local
  # Browser: complete Google OAuth
  ```
- [ ] **S2: m365 login for James** (headless, client credentials -- no browser needed):
  ```bash
  docker exec openclaw-gateway sh -c \
    'm365 login --authType secret \
      --appId "$(cat /run/secrets/m365-client-id-james)" \
      --tenant "$(cat /run/secrets/m365-tenant-id-james)" \
      --secret "$(cat /run/secrets/m365-client-secret-james)"'
  ```
- [ ] **S3: Pair both agents on Telegram**

### Phase 4: Verify

- [ ] **V1: Gateway health**: `curl http://10.17.1.40:18789/health`
- [ ] **V2: Percy responds on Telegram** -- send message to `@percaival_bot`
- [ ] **V3: James responds on Telegram** -- send message to James's bot
- [ ] **V4: Percy Mattermost still works**
- [ ] **V5: Agent-to-agent comm**: Ask Percy "Send a message to James saying hello"
- [ ] **V6: Percy state intact**: past conversations, skills, cron jobs all work
- [ ] **V7: Git push from both agents**: trigger workspace change, verify commits under correct GitHub accounts
- [ ] **V8: Shared workspace**: both agents can read `shared/KB.md`
- [ ] **V9: James SSH**: `docker exec openclaw-gateway ssh miniserver-bp.local "hostname && whoami"`
- [ ] **V10: Nightly cron**: verify crontab registered (Percy: 23:30, James: 23:31)
- [ ] **V11: James gog**: `docker exec openclaw-gateway sh -c '. /home/node/.config/james/gogcli/gogcli.env && gog auth list'`
- [ ] **V12: James m365**: `docker exec openclaw-gateway m365 status` (shows James-AI connection)

### Phase 5: Documentation

- [ ] **D1: Update `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md`**:
  - Reflect multi-agent architecture, new paths, new commands
  - Add James to all tables (secrets, skills, identities, status)
  - Add shared workspace section
  - Update all `openclaw-percaival` references -> `openclaw-gateway`
  - Add James SSH access section
- [ ] **D2: Update `hosts/miniserver-bp/README.md`** -- add James to features, update firewall comment
- [ ] **D3: Update `docs/INFRASTRUCTURE.md`** -- add James identity to miniserver-bp section
- [ ] **D4: Update both agent `AGENTS.md` files** in workspace repos (reference shared workspace)
- [ ] **D5: Fix git noreply emails for both agents** -- verify numeric prefix from GitHub
- [ ] **D6: Remove backups after 30 days**:
  ```bash
  # On miniserver-bp:
  sudo trash /var/lib/openclaw-percaival-backup-*
  # On mba-imac-work:
  trash ~/Desktop/msbp-backup/
  ```

---

## Rollback Plan

If anything goes wrong after Phase 2:

```bash
# 1. Stop new container
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker compose stop openclaw-gateway

# 2. Restore Percy state from backup
sudo cp -a /var/lib/openclaw-percaival-backup-*/. /var/lib/openclaw-percaival/

# 3. Revert git changes
cd ~/Code/nixcfg
git revert HEAD

# 4. Rebuild old config
just switch
cd hosts/miniserver-bp/docker
docker compose up -d --build --force-recreate openclaw-percaival

# 5. Verify Percy is back
docker logs -f openclaw-percaival
```

---

## Acceptance Criteria

- [ ] Single `openclaw-gateway` container runs both agents
- [ ] Percy responds on existing Telegram bot with full state/memory preserved
- [ ] James responds on his own Telegram bot
- [ ] Agent state (DB/sessions/workspace) is fully isolated
- [ ] Agents can communicate in real-time using `sessions_send`
- [ ] Percy's existing skills (gog, m365-email, openrouter-free-models) still work
- [ ] James has gog + m365 with his own `james.ai@bytepoets.com` identity
- [ ] James has SSH access to miniserver-bp as `james` user
- [ ] Shared workspace (`oc-workspace-shared-bp`) with nightly cron sync
- [ ] Commits from James appear under `bytepoets-jamesai` GitHub account
- [ ] `just percy-rebuild`, `just percy-status`, `just percy-pull-workspace`, `just james-pull-workspace` all work
- [ ] OPENCLAW-RUNBOOK.md, README.md, INFRASTRUCTURE.md updated
- [ ] Backups verified and retention period set

---

## Files Modified (Complete List)

| File                                                         | Change                                                       |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| `hosts/miniserver-bp/docker/openclaw-percaival/`             | **Renamed** -> `openclaw-gateway/`                           |
| `hosts/miniserver-bp/docker/openclaw-gateway/Dockerfile`     | Add cron, sudo, ssh; per-agent dirs                          |
| `hosts/miniserver-bp/docker/openclaw-gateway/entrypoint.sh`  | **Rewritten** for multi-agent loop                           |
| `hosts/miniserver-bp/docker/openclaw-gateway/openclaw.json`  | **Rewritten** with `agents.list`, `bindings`, `agentToAgent` |
| `hosts/miniserver-bp/docker/openclaw-gateway/shared-sync.sh` | **New** -- nightly shared workspace sync                     |
| `hosts/miniserver-bp/docker/docker-compose.yml`              | Service rename + new volume mounts                           |
| `hosts/miniserver-bp/configuration.nix`                      | New agenix secrets, james user, activation script migration  |
| `secrets/secrets.nix`                                        | New `miniserver-bp-james-*.age` entries                      |
| `secrets/miniserver-bp-james-telegram-token.age`             | **New** (encrypted)                                          |
| `secrets/miniserver-bp-james-github-pat.age`                 | **New** (encrypted)                                          |
| `secrets/miniserver-bp-james-gogcli-keyring-password.age`    | **New** (encrypted)                                          |
| `secrets/miniserver-bp-james-m365-client-id.age`             | **New** (encrypted)                                          |
| `secrets/miniserver-bp-james-m365-tenant-id.age`             | **New** (encrypted)                                          |
| `secrets/miniserver-bp-james-m365-client-secret.age`         | **New** (encrypted)                                          |
| `secrets/miniserver-bp-james-ssh-key.age`                    | **New** (encrypted)                                          |
| `justfile`                                                   | Replace `[percy]` group with `[openclaw-bp]` group           |
| `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md`               | Updated for multi-agent                                      |
| `hosts/miniserver-bp/README.md`                              | Add James to features, update firewall comment               |
| `docs/INFRASTRUCTURE.md`                                     | Add James identity                                           |

## Notes

- **Percy agentId migration**: Percy's current `agentId` is `"main"`. Changing to `"percy"` means
  the agent state directory changes from `agents/main/` to `agents/percy/`. The activation script
  must handle this: if `agents/main/` exists and `agents/percy/` doesn't, move it. Otherwise Percy
  loses all paired devices, session history, and auth-profiles.
- **Mattermost binding**: current Percy config has a single Mattermost channel. Decide whether both
  agents share one bot token (with routing via mention patterns) or James gets a separate Mattermost
  bot. The simpler approach is shared token + mention-based routing.
- **Percy rebuild time**: ~15 min due to pip installing pymupdf4llm + pdfplumber. Plan accordingly.
  Use `oc-rebuild-fast` (cached) for non-Dockerfile changes.
- **Reference implementation**: `+pm/done/P40--339a6f7--setup-nimue-multi-agent.md` -- follow this
  pattern exactly for the multi-agent migration.
- **Shared workspace**: uses BYTEPOETS-specific shared repo (`oc-workspace-shared-bp`), NOT the
  home/family `oc-workspace-shared`. Different context, different teams.

## References

- hsb0 multi-agent migration: `+pm/done/P40--339a6f7--setup-nimue-multi-agent.md`
- hsb0 shared workspace: `hosts/hsb0/docs/backlog/P40--03b5470--shared-workspace-merlin-nimue.md`
- Percy current RUNBOOK: `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md`
- hsb0 RUNBOOK (reference): `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`
- OpenClaw Multi-Agent Routing: `https://docs.openclaw.ai/concepts/multi-agent`
