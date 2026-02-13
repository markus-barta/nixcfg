# OpenClaw Runbook - miniserver-bp

**Host**: miniserver-bp (10.17.1.40)
**Instance**: Percaival
**Port**: 18789
**Version**: 2026.2.9 (npm)
**Updated**: 2026-02-13

---

## Current Status

| Component      | Status           | Notes                  |
| -------------- | ---------------- | ---------------------- |
| Container      | ✅ Running       | 19+ hours uptime       |
| Telegram       | ✅ Connected     | @percaival_bot         |
| gog (Google)   | ✅ Working       | percy.ai@bytepoets.com |
| weather        | ✅ Ready         | Bundled skill          |
| healthcheck    | ✅ Ready         | Bundled skill          |
| Skills (other) | ❌ Not installed | See below              |

## Available Skills

OpenClaw loads skills from three layers: bundled (npm package), managed (`~/.openclaw/skills`), and workspace (`<workspace>/skills`). See [OPENCLAW-DOCKER-SETUP.md](./OPENCLAW-DOCKER-SETUP.md#skills) for full details on precedence and paths.

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

None installed yet. Use ClawHub CLI or manual git-clone — see "Adding Skills" below.

## Operational Commands

### Check Status

```bash
# Container status
sudo systemctl status docker-openclaw-percaival
docker ps | grep openclaw

# View logs
docker logs -f openclaw-percaival

# Gateway health
curl http://10.17.1.40:18789/health
```

### Restart

```bash
sudo systemctl restart docker-openclaw-percaival
```

### Stop (Prevent Auto-Restart)

```bash
sudo systemctl mask docker-openclaw-percaival
sudo systemctl stop docker-openclaw-percaival
# Later: sudo systemctl unmask docker-openclaw-percaival
```

### View Config

```bash
# Current config
cat /var/lib/openclaw-percaival/data/openclaw.json | jq

# Gateway token
docker exec openclaw-percaival openclaw dashboard --no-open
```

### Edit Config

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

### Re-authenticate (if needed)

See: [OPENCLAW-DOCKER-SETUP.md](./OPENCLAW-DOCKER-SETUP.md) - gogcli setup section

### Keyring Password

The gog keyring password is stored in agenix:

- Secret: `miniserver-bp-gogcli-keyring-password.age`
- Format in secret: `GOG_KEYRING_PASSWORD=<password>`
- Injected via NixOS config to container environment

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

sudo systemctl restart docker-openclaw-percaival
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

Full architecture details: [OPENCLAW-DOCKER-SETUP.md](./OPENCLAW-DOCKER-SETUP.md#multi-agent-architecture)

### List agents

```bash
docker exec openclaw-percaival openclaw agents list --bindings
```

### Add agent (quick steps)

1. Create workspace dir on host
2. Add to `agents.list[]` + `bindings[]` in `openclaw.json`
3. Add bot token if new Telegram bot (via agenix)
4. `sudo systemctl restart docker-openclaw-percaival`

See [OPENCLAW-DOCKER-SETUP.md — Adding a second agent](./OPENCLAW-DOCKER-SETUP.md#multi-agent-architecture) for full checklist.

---

## Files Reference

| What                    | Location                                               |
| ----------------------- | ------------------------------------------------------ |
| Dockerfile              | `hosts/miniserver-bp/docker/Dockerfile`                |
| NixOS config            | `hosts/miniserver-bp/configuration.nix`                |
| Config (host)           | `/var/lib/openclaw-percaival/data/openclaw.json`       |
| Workspace               | `/var/lib/openclaw-percaival/data/workspace/`          |
| Telegram token (agenix) | `secrets/miniserver-bp-openclaw-telegram-token.age`    |
| gogcli keyring (agenix) | `secrets/miniserver-bp-gogcli-keyring-password.age`    |
| Container logs          | `docker logs openclaw-percaival`                       |
| Gateway log             | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (in container) |
| gogcli config           | `/var/lib/openclaw-percaival/gogcli/`                  |

## Access

| Service    | URL                      |
| ---------- | ------------------------ |
| Control UI | http://10.17.1.40:18789/ |
| Telegram   | @percaival_bot           |

## Related Documentation

- [OPENCLAW-DOCKER-SETUP.md](./OPENCLAW-DOCKER-SETUP.md) - Installation, architecture, gotchas, deployment approach
- [OPENCLAW-DOCKER-SETUP.md](./OPENCLAW-DOCKER-SETUP.md#investigation-log-docker-bridge-vs-loopback) - Investigation Log (below)
- Backlog: `hosts/miniserver-bp/docs/backlog/`

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

### Pairing architecture

OpenClaw has two distinct connection paths:

1. **In-process agent runtime** — the embedded agent, cron scheduler, and channel connectors (Telegram, etc.) run inside the gateway process. Not subject to device pairing. This is why cron and Telegram work.

2. **CLI RPC commands** — `openclaw devices list`, `openclaw gateway status`, etc. connect via WebSocket RPC. This path enforces device pairing even on loopback. `openclaw doctor` is an exception (reads state directly, no RPC).
