# OpenClaw Docker Setup on miniserver-bp

**Host**: miniserver-bp (10.17.1.40)
**Instance**: Percaival
**Port**: 18789
**Version**: 2026.2.9 (npm)
**Created**: 2026-02-11

---

## Architecture

```
NixOS (oci-containers) → Docker → node:22-bookworm-slim + openclaw@latest
                                   ↓
                          /home/node/.openclaw (volume mount)
                                   ↓
                          /var/lib/openclaw-percaival/data (host)
```

- NixOS manages container lifecycle via `virtualisation.oci-containers`
- Systemd service: `docker-openclaw-percaival`
- Image built from `hosts/miniserver-bp/docker/Dockerfile`
- Config + data persisted at `/var/lib/openclaw-percaival/data/`
- Telegram token injected into `openclaw.json` via agenix activation script

## Lessons Learned / Gotchas

### 1. No official Docker image on DockerHub

OpenClaw has no pre-built image. Options:

- **Option A**: Clone repo + `docker build` (full monorepo build, heavy)
- **Option B**: Simple `FROM node:22-bookworm-slim` + `npm install -g openclaw@latest` (our choice)
- **Option C**: Use Nix package (exists at `pkgs/openclaw/package.nix`)

We chose B — simplest, matches official npm install path.

### 2. git is required for npm install

The `-slim` image doesn't include git. OpenClaw's npm package needs it during install.

```dockerfile
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
```

### 3. Run as `node` user, not root

Without `USER node`, the container runs as root. This means:

- `$HOME` is `/root/`, not `/home/node/`
- `~/.openclaw/` resolves to `/root/.openclaw/` — mismatches the volume mount
- Onboard wizard writes config to wrong location

Fix: add to Dockerfile:

```dockerfile
RUN mkdir -p /home/node/.openclaw/workspace && chown -R node:node /home/node/.openclaw
USER node
```

### 4. Onboard wizard must run BEFORE gateway

The gateway spins at 99% CPU if started without onboarding. The CMD starts `openclaw gateway` immediately, but it needs config from the onboard wizard first.

**First-time setup flow:**

```bash
# 1. Mask the service so NixOS doesn't auto-restart
sudo systemctl mask docker-openclaw-percaival
sudo systemctl stop docker-openclaw-percaival

# 2. Run onboard in a one-off container
docker run -it --rm \
  -v /var/lib/openclaw-percaival/data:/home/node/.openclaw:rw \
  openclaw-percaival:latest \
  openclaw onboard

# 3. Unmask and start
sudo systemctl unmask docker-openclaw-percaival
sudo systemctl start docker-openclaw-percaival
```

Note: `docker stop` won't work alone — NixOS systemd service auto-restarts. Use `systemctl mask`.

### 5. Use `--network=host` + `bind=lan` (required)

With default Docker bridge networking, the embedded agent connects to the gateway via the container's bridge IP (e.g. `172.17.0.3`). The gateway treats this as external and enforces device pairing — breaking cron and internal tools.

**The fix: `--network=host`**. The container shares the host's network stack. No Docker bridge, no bridge IP. Port 18789 is directly on the host (no Docker port mapping needed).

Use `gateway.bind: "lan"` in `openclaw.json` — the gateway listens on `0.0.0.0`, accessible from the office LAN for the Control UI.

```nix
virtualisation.oci-containers.containers.openclaw-percaival = {
  image = "openclaw-percaival:latest";
  extraOptions = [ "--network=host" ];
  volumes = [ "/var/lib/openclaw-percaival/data:/home/node/.openclaw:rw" ];
  autoStart = true;
};
```

```json5
// openclaw.json
{ gateway: { bind: "lan" } }
```

**Verified working with this setup:**

- Telegram DMs and group chat
- Cron jobs
- Internal tools
- `openclaw doctor`
- Control UI from browser at `http://10.17.1.40:18789/` (with `allowInsecureAuth`)

**What doesn't work (cosmetic, does not affect agent functionality):**

- `openclaw devices list` — "pairing required" via CLI RPC
- `openclaw gateway status` — RPC probe fails (but shows correct config)
- Other CLI RPC commands that connect via WebSocket

**Note on `bind=auto`**: We also tested `bind=auto` — it binds to loopback only, making the Control UI inaccessible from LAN. Since the agent runtime is in-process (works regardless of bind mode), `bind=lan` is the better choice.

**Trade-off**: `--network=host` reduces container network isolation. Acceptable for a test server on office LAN.

### 6. Control UI requires `allowInsecureAuth` over HTTP

Accessing `http://10.17.1.40:18789/#token=...` fails with:

```
disconnected (1008): control ui requires HTTPS or localhost (secure context)
```

Fix — add to `openclaw.json`:

```json5
{
  gateway: {
    controlUi: {
      allowInsecureAuth: true,
    },
  },
}
```

Acceptable for office LAN. For production, use Tailscale Serve or reverse proxy with TLS.

### 7. Systemd unavailable in container — expected

Onboard warns:

```
Systemd user services are unavailable. Skipping lingering checks and service install.
```

This is fine — NixOS manages the container lifecycle, not systemd inside the container.

### 8. Missing Control UI assets — cosmetic, not blocking

npm package doesn't ship pre-built UI. Warning:

```
Missing Control UI assets. Build them with `pnpm ui:build`
```

The gateway + Telegram channel works without it. The Control UI is a browser dashboard for settings management — nice-to-have, not required.

### 9. agenix files are raw content, not KEY=VALUE

`environmentFiles` in oci-containers expects `KEY=VALUE` format. Agenix decrypts to raw content.

Solution: activation script templates `openclaw.json` with token baked in:

```nix
system.activationScripts.openclaw-percaival = ''
  TOKEN=$(cat ${config.age.secrets.miniserver-bp-openclaw-telegram-token.path})
  cat > /var/lib/openclaw-percaival/data/openclaw.json << EOF
  { ... "botToken": "$TOKEN" ... }
  EOF
  chown -R 1000:1000 /var/lib/openclaw-percaival/data
'';
```

Note: onboard wizard overwrites `openclaw.json` — token must be re-added or use `TELEGRAM_BOT_TOKEN` env var instead.

### 10. Nix package is not a viable alternative

The Nix package (`pkgs/openclaw/package.nix`) exists but is **not recommended**. Experience from hsb1 deployment: OpenClaw updates frequently and aggressively, the Node.js dependency tree is volatile, and npm postinstall scripts break in the Nix sandbox. Keeping the package up to date requires constant patching. Native Nix packaging for OpenClaw is a maintenance nightmare — Docker (despite its issues) is far more practical.

### 11. npm install vs official Dockerfile — resolved

Our approach (`npm install -g openclaw@latest`) works fine with `--network=host`. The official repo Dockerfile uses a full `pnpm build` but has the same gateway auth logic — it would hit the same pairing issue on bridge networking. The pairing problem is a Docker networking issue, not an npm vs source build issue. See investigation log below.

### 12. Tailscale exposure — skip for now

Onboard offers Tailscale Serve/Funnel. Select **Off** — we handle access via Docker port mapping + firewall. Tailscale Serve can be added later if needed.

## Common Operations

### Check status

```bash
sudo systemctl status docker-openclaw-percaival
docker ps | grep openclaw
docker logs -f openclaw-percaival
```

### Restart

```bash
sudo systemctl restart docker-openclaw-percaival
```

### Stop (prevent auto-restart)

```bash
sudo systemctl mask docker-openclaw-percaival
sudo systemctl stop docker-openclaw-percaival
# Later: sudo systemctl unmask docker-openclaw-percaival
```

### Edit config

```bash
sudo vim /var/lib/openclaw-percaival/data/openclaw.json
sudo systemctl restart docker-openclaw-percaival
```

### Update OpenClaw

```bash
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker build --no-cache -t openclaw-percaival:latest .
sudo systemctl restart docker-openclaw-percaival
```

### View gateway token

```bash
docker exec openclaw-percaival openclaw dashboard --no-open
```

### Pair Telegram

**Initial setup (one-time):**

```bash
docker exec openclaw-percaival openclaw channels add --channel telegram --token "<token>"
```

**Approve pairing requests:**
When someone DMs the bot, they'll receive a pairing code. Approve it:

```bash
docker exec -it openclaw-percaival openclaw pairing approve telegram <YOURPAIRINGCODE>
```

**List pending pairings:**

```bash
docker exec -it openclaw-percaival openclaw pairing list telegram
```

## Skills

### How Skills Work

OpenClaw loads skills from **three locations** (highest precedence first):

| Priority | Location (in container) | Host path                                            | What                      |
| -------- | ----------------------- | ---------------------------------------------------- | ------------------------- |
| Highest  | `<workspace>/skills`    | `/var/lib/openclaw-percaival/data/workspace/skills/` | Per-agent, user-installed |
| Middle   | `~/.openclaw/skills`    | `/var/lib/openclaw-percaival/data/skills/`           | Shared across agents      |
| Lowest   | Bundled (npm package)   | Inside container node_modules                        | Ships with OpenClaw       |

Same-name skill in a higher-priority location **overrides** lower ones. Skills are picked up on next session start (or via hot-reload if watcher is enabled).

Additional skill dirs can be configured via `skills.load.extraDirs` in `openclaw.json`.

Docs: https://docs.openclaw.ai/tools/skills

### Bundled Skills

These ship with the npm package and are available out of the box (~50 total). Key ones for Percaival:

| Skill       | Status    | Notes                                                               |
| ----------- | --------- | ------------------------------------------------------------------- |
| gog         | ✅ Active | Google Workspace — requires gogcli binary (installed in Dockerfile) |
| weather     | ✅ Ready  | Current weather and forecasts                                       |
| healthcheck | ✅ Ready  | Host security hardening                                             |

All other bundled skills are available but may require binaries or API keys. Enable/disable via `openclaw.json`:

```json5
{ skills: { entries: { "some-skill": { enabled: false } } } }
```

### Declarative vs Non-Declarative

| Aspect       | Declarative (Nix/Agenix)           | Non-Declarative (Container)         |
| ------------ | ---------------------------------- | ----------------------------------- |
| **What**     | Secrets, container config          | Skills, openclaw.json runtime state |
| **How**      | NixOS `configuration.nix` + agenix | ClawHub CLI or manual install       |
| **Persists** | Yes (nix store / agenix)           | Yes (in `/var/lib/`)                |
| **Examples** | Telegram token, gogcli password    | Workspace skills, agent docs        |

Skills are not managed via Nix — they live in the container's persistent volume.

### Managing Skills with ClawHub

[ClawHub](https://clawhub.ai) is the public skill registry. The `clawhub` CLI is the recommended way to install, update, and track skills.

```bash
# Install CLI (already available if added to Dockerfile, otherwise:)
docker exec -it openclaw-percaival npm install -g clawhub

# Search for skills
docker exec -it openclaw-percaival clawhub search "calendar"

# Install a skill (into workspace/skills/)
docker exec -it openclaw-percaival clawhub install <skill-slug>

# Update all installed skills
docker exec -it openclaw-percaival clawhub update --all

# List installed (reads .clawhub/lock.json)
docker exec -it openclaw-percaival clawhub list
```

Docs: https://docs.openclaw.ai/tools/clawhub

### Manual Skill Install (alternative)

For skills not on ClawHub, or for development:

```bash
# SSH to miniserver-bp
ssh -p 2222 mba@10.17.1.40

# Create skills directory if needed
sudo mkdir -p /var/lib/openclaw-percaival/data/workspace/skills
sudo chown -R 1000:1000 /var/lib/openclaw-percaival/data/workspace

# Clone skill (example: m365-skill)
cd /var/lib/openclaw-percaival/data/workspace/skills
sudo git clone https://github.com/cvsloane/m365-skill ms365

# Restart container (or start new session)
sudo systemctl restart docker-openclaw-percaival
```

### Brave Web Search

OpenClaw uses Brave Search for the `web_search` tool. Without a Brave Search API key, web search won't work.

**Setup:**

```bash
docker exec -it openclaw-percaival openclaw config set tools.web.search.apiKey "YOUR_BRAVE_API_KEY"
docker restart openclaw-percaival
```

Alternative: set `BRAVE_API_KEY` in the gateway environment (no config change needed).

Docs: https://docs.openclaw.ai/tools/web

### Google Suite CLI (gogcli)

[gogcli](https://github.com/steipete/gogcli) provides Gmail, Calendar, Drive, Contacts, Tasks, Sheets, and more as CLI commands. Installed inside the container from pre-built release binary (v0.9.0).

**Container environment** (set via NixOS config):

- `GOG_KEYRING_BACKEND=file` — uses encrypted on-disk keyring (no OS keychain in container)
- `GOG_KEYRING_PASSWORD` — injected via agenix (`miniserver-bp-gogcli-keyring-password.age`, format: `GOG_KEYRING_PASSWORD=<password>`)
- `GOG_ACCOUNT=percy.ai@bytepoets.com` — default account

**Credentials persistence**: gogcli config is stored at `/var/lib/openclaw-percaival/gogcli/` on the host (mounted to `/home/node/.config/gogcli/` in the container).

#### Google Cloud project setup

The OAuth client must belong to a Google Cloud project with the required APIs enabled. Enable them at:

- Gmail API: `https://console.cloud.google.com/apis/api/gmail.googleapis.com`
- Google Calendar API: `https://console.cloud.google.com/apis/api/calendar-json.googleapis.com`
- Google Drive API: `https://console.cloud.google.com/apis/api/drive.googleapis.com`
- People API (Contacts): `https://console.cloud.google.com/apis/api/people.googleapis.com`
- Google Tasks API: `https://console.cloud.google.com/apis/api/tasks.googleapis.com`
- Google Sheets API: `https://console.cloud.google.com/apis/api/sheets.googleapis.com`

Our project ID: `793253295853`. If a `gog` command fails with "API not enabled", check the link above for the relevant API.

#### First-time OAuth setup

The container runs headless — no browser. The auth flow uses a local HTTP callback on a random port. Since the container uses `--network=host`, the callback listener is on miniserver-bp's network.

```bash
# 1. Copy OAuth client JSON to the host (from your workstation)
scp -P 2222 ~/Downloads/client_secret_....json mba@10.17.1.40:/tmp/

# 2. SSH to miniserver-bp
ssh -p 2222 mba@10.17.1.40

# 3. Move to gogcli volume and fix ownership
sudo mv /tmp/client_secret_....json /var/lib/openclaw-percaival/gogcli/client_secret.json
sudo chown 1000:1000 /var/lib/openclaw-percaival/gogcli/client_secret.json

# 4. Store credentials in gogcli (use full container path)
docker exec -it -e GOG_KEYRING_BACKEND=file openclaw-percaival \
  gog auth credentials /home/node/.config/gogcli/client_secret.json

# 5. Start OAuth flow (will print a Google auth URL and wait for callback)
#    NOTE: --remote flag does NOT exist in v0.9.0. Use the callback approach below.
docker exec -it -e GOG_KEYRING_BACKEND=file openclaw-percaival \
  gog auth add percy.ai@bytepoets.com

# 6. Copy the printed Google auth URL -> open in browser on your workstation
#    Authorize the account in Google.
#    Google redirects to http://127.0.0.1:<port>/oauth2/callback?code=...&state=...
#    This fails in your browser (wrong machine). Copy the FULL redirect URL from the address bar.

# 7. In a SECOND terminal on miniserver-bp, curl the redirect URL:
curl "http://127.0.0.1:<port>/oauth2/callback?code=...&state=..."
#    The gog listener receives the callback and completes the OAuth exchange.
#    It will prompt for a keyring passphrase — enter the same password stored in agenix.

# 8. Verify
docker exec -it -e GOG_KEYRING_BACKEND=file openclaw-percaival \
  gog auth list
```

**Alternative (SSH tunnel)**: Forward the callback port so your browser hits miniserver-bp directly. Run this _before_ step 5:

```bash
# From your workstation (use the port number from the auth URL):
ssh -p 2222 -L <port>:127.0.0.1:<port> mba@10.17.1.40
```

Then the browser redirect to `127.0.0.1:<port>` tunnels to miniserver-bp automatically — no manual curl needed.

**After NixOS rebuild**: The container gets `GOG_KEYRING_PASSWORD` via agenix env file, so gogcli works non-interactively (no passphrase prompts for OpenClaw tool calls).

**Docs**: https://github.com/steipete/gogcli

## Multi-Agent Architecture

One gateway process can host **multiple agents** — no separate containers needed. Each agent is a fully isolated "brain" with its own workspace, identity, sessions, auth, and memory.

Docs: https://docs.openclaw.ai/concepts/multi-agent

### Isolation (per agent)

| Component                               | Isolated by               | Path (in container)                      |
| --------------------------------------- | ------------------------- | ---------------------------------------- |
| Workspace (persona, AGENTS.md, SOUL.md) | `agents.list[].workspace` | `~/.openclaw/workspace-<agentId>`        |
| State & auth profiles                   | `agents.list[].agentDir`  | `~/.openclaw/agents/<agentId>/agent/`    |
| Sessions (chat history)                 | Per-agent store           | `~/.openclaw/agents/<agentId>/sessions/` |
| Memory (daily logs, MEMORY.md)          | Per-workspace             | `<workspace>/memory/`                    |
| Memory search index                     | Per-agent SQLite          | `~/.openclaw/memory/<agentId>.sqlite`    |
| Workspace skills                        | Per-workspace             | `<workspace>/skills/`                    |

**Never reuse `agentDir` across agents** — causes auth/session collisions.

### Sharing (built-in mechanisms)

OpenClaw provides explicit config-based sharing. **Do NOT use symlinks** — the memory search indexer explicitly ignores them.

| What to share          | Mechanism                            | Config key                                                           |
| ---------------------- | ------------------------------------ | -------------------------------------------------------------------- |
| Skills (common pack)   | Extra skill dirs (lowest precedence) | `skills.load.extraDirs: ["/path/to/shared/skills"]`                  |
| Skills (all agents)    | Managed skills dir                   | Install to `~/.openclaw/skills/` (shared by default)                 |
| Knowledge / notes      | Extra memory search paths            | `agents.defaults.memorySearch.extraPaths: ["/path/to/shared-notes"]` |
| API keys, model config | Global config                        | `skills.entries`, `tools.web`, `models.providers` in `openclaw.json` |
| Google auth (gogcli)   | Copy auth-profiles.json              | Copy between agent dirs (not symlink)                                |
| Agent-to-agent comms   | Opt-in messaging                     | `tools.agentToAgent: { enabled: true, allow: ["a", "b"] }`           |

### Routing (bindings)

Inbound messages are routed to agents via `bindings` in `openclaw.json`. Deterministic, most-specific wins:

1. `match.peer` (exact DM/group id)
2. `match.guildId` / `match.teamId`
3. `match.accountId` (exact)
4. `match.accountId: "*"` (channel-wide)
5. Default agent (`agents.list[].default`, else first entry)

Example — two Telegram bots, one gateway:

```json5
{
  agents: {
    list: [
      {
        id: "percaival",
        workspace: "~/.openclaw/workspace-percaival",
        identity: { name: "Percaival", emoji: "⚔️" },
      },
      {
        id: "other",
        workspace: "~/.openclaw/workspace-other",
        identity: { name: "Other Bot", emoji: "🤖" },
      },
    ],
  },
  bindings: [
    {
      agentId: "percaival",
      match: { channel: "telegram", accountId: "default" },
    },
    {
      agentId: "other",
      match: { channel: "telegram", accountId: "other-bot" },
    },
  ],
  channels: {
    telegram: {
      accounts: {
        default: { botToken: "..." },
        "other-bot": { botToken: "..." },
      },
    },
  },
}
```

### Per-agent overrides

Each agent can have its own model, sandbox, tool restrictions, and identity:

```json5
{
  agents: {
    list: [
      {
        id: "fast-chat",
        model: "anthropic/claude-sonnet-4-5",
        sandbox: { mode: "off" },
      },
      {
        id: "deep-work",
        model: "anthropic/claude-opus-4-6",
        tools: { deny: ["browser"] },
        sandbox: { mode: "all", scope: "agent" },
      },
    ],
  },
}
```

### Adding a second agent (checklist)

1. Create new workspace dir on host (e.g. `/var/lib/openclaw-percaival/data/workspace-<agentId>`)
2. Add agent to `agents.list[]` in `openclaw.json` with unique `id`, `workspace`, `agentDir`
3. Add `bindings[]` entry to route channel/peer to the new agent
4. If new Telegram bot: add bot token to `channels.telegram.accounts` (via agenix)
5. Restart gateway: `sudo systemctl restart docker-openclaw-percaival`
6. Bootstrap: the agent auto-creates workspace files on first session (or use `openclaw setup`)

### Current state

Single-agent mode (default `agentId: "main"`, workspace at `/var/lib/openclaw-percaival/data/`). Ready for multi-agent when needed — config change only, no container changes.

Docs:

- Multi-agent routing: https://docs.openclaw.ai/concepts/multi-agent
- Multi-agent sandbox & tools: https://docs.openclaw.ai/tools/multi-agent-sandbox-tools
- Skills config: https://docs.openclaw.ai/tools/skills-config
- Agent workspace: https://docs.openclaw.ai/concepts/agent-workspace

## Files

| What                       | Where                                                                          |
| -------------------------- | ------------------------------------------------------------------------------ |
| Dockerfile                 | `hosts/miniserver-bp/docker/Dockerfile`                                        |
| NixOS config               | `hosts/miniserver-bp/configuration.nix` (lines 215-226, 240-256)               |
| Config (host)              | `/var/lib/openclaw-percaival/data/openclaw.json`                               |
| Workspace (host)           | `/var/lib/openclaw-percaival/data/workspace/`                                  |
| Agenix secret (Telegram)   | `secrets/miniserver-bp-openclaw-telegram-token.age`                            |
| Agenix secret (gogcli)     | `secrets/miniserver-bp-gogcli-keyring-password.age`                            |
| Backlog item               | `hosts/miniserver-bp/docs/backlog/P80--5c21a08--install-openclaw-percaival.md` |
| Container logs             | `docker logs openclaw-percaival`                                               |
| Gateway log (in container) | `/tmp/openclaw/openclaw-YYYY-MM-DD.log`                                        |
| gogcli config (host)       | `/var/lib/openclaw-percaival/gogcli/`                                          |

## Network

| Port  | Service            | Firewall |
| ----- | ------------------ | -------- |
| 2222  | SSH                | Open     |
| 8888  | pm-tool            | Open     |
| 18789 | OpenClaw Percaival | Open     |

## Investigation Log: Docker Bridge vs Loopback

See: [OPENCLAW-RUNBOOK.md](./OPENCLAW-RUNBOOK.md) for the detailed investigation log (what didn't work, what works, pairing architecture).

## Deployment Approach Comparison

| Approach                                                  | Pros                  | Cons                                           | Status                           |
| --------------------------------------------------------- | --------------------- | ---------------------------------------------- | -------------------------------- |
| **Option A**: Official Dockerfile (full repo build)       | Official              | Heavy build, slow updates, same auth logic     | Not viable (doesn't fix pairing) |
| **Option B**: npm install + `--network=host` + `bind=lan` | Simple, fast, working | Reduced network isolation, CLI RPC broken      | **In use, working**              |
| **Option C**: Nix package + systemd                       | No container overhead | Brittle, constant patching, npm sandbox breaks | Tested on hsb1 — not recommended |

## References

- Docs: https://docs.openclaw.ai/
- Docker install: https://docs.openclaw.ai/install/docker
- Config reference: https://docs.openclaw.ai/gateway/configuration
- Health check: https://docs.openclaw.ai/gateway/health
- Troubleshooting: https://docs.openclaw.ai/gateway/troubleshooting
