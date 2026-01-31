# P9400 - HSB1: OpenClaw AI Assistant Deployment

## Context

Deploy [OpenClaw](https://openclaw.ai/) (personal AI assistant) on hsb1 in **hybrid mode** — native Gateway with sandboxed tools. This provides full "hands" capability (host tools, browser automation, file access) while maintaining security through per-session sandboxing for untrusted chats.

## Package Source

**Using upstream nix-openclaw flake** (`github:openclaw/nix-openclaw`) - NOT vendored.

This provides:

- Pre-built pnpm-based package (no npm cache issues)
- Garnix binary cache available (faster builds)
- Batteries-included: gateway + CLI tools bundle
- Maintained upstream (proper build scripts, platform support)

**Flake input:** `inputs.nix-openclaw` → `pkgs.openclaw`

## Goals

- **Full functionality**: AI can manage hsb1 services, edit configs, check Docker containers
- **Security**: Personal DMs have full access, group chats sandboxed
- **Remote access**: Telegram bot works from anywhere
- **Control**: NixOS-native deployment, managed via `/etc/nixos`, secrets via agenix

## Architecture Decision

| Aspect            | Choice                 | Rationale                                     |
| ----------------- | ---------------------- | --------------------------------------------- |
| **Deployment**    | Native NixOS service   | Full host tool access, systemd integration    |
| **Sandboxing**    | `mode: "non-main"`     | Personal DMs native, groups/channels isolated |
| **Channel**       | Telegram               | Bot token auth, works from anywhere           |
| **LLM**           | OpenRouter (Kimi K2.5) | Via API key, no OAuth complexity              |
| **Remote Access** | Telegram bot           | No VPN/SSH tunnel needed                      |

## Prerequisites

- [x] hsb1 backup validated (latest: Jan 31, snapshot `5f1e7fa7`)
- [x] Node.js 22+ available → included in upstream `nix-openclaw` package
- [ ] OpenRouter API key (store in 1Password, then encrypt via agenix)
- [ ] Telegram Bot Token (create via @BotFather, then encrypt via agenix)
- [ ] Verify `mba` user in `docker` group (for sandbox containers)

## Configuration Plan

### 1. NixOS Configuration Structure

Following nixcfg conventions (secrets in top-level `secrets/`, config inline in host):

```
secrets/                              # Top-level secrets (agenix pattern)
├── hsb1-openclaw-gateway-token.age
├── hsb1-openclaw-telegram-token.age
└── hsb1-openclaw-openrouter-key.age

hosts/hsb1/
├── configuration.nix                 # Add OpenClaw service inline
└── docs/
    └── OPENCLAW.md                   # Operational guide
```

**Why inline vs module?** Single-host deployment; if we deploy to multiple hosts later, extract to `modules/openclaw/`.

### 2. OpenClaw Configuration (~/.openclaw/openclaw.json)

```json
{
  "gateway": {
    "bind": "0.0.0.0",
    "port": 18789,
    "auth": {
      "tokenFile": "/run/agenix/hsb1-openclaw-gateway-token"
    }
  },
  "agents": {
    "defaults": {
      "model": "openrouter/kimi-k2.5",
      "sandbox": {
        "mode": "non-main",
        "scope": "session",
        "workspaceAccess": "rw",
        "docker": {
          "image": "openclaw-sandbox:bookworm-slim",
          "network": "none",
          "readOnlyRoot": true,
          "user": "1000:1000"
        }
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "tokenFile": "/run/agenix/hsb1-openclaw-telegram-token"
    }
  },
  "providers": {
    "openrouter": {
      "apiKeyFile": "/run/agenix/hsb1-openclaw-openrouter-key"
    }
  }
}
```

### 3. Secrets Management (agenix)

| Secret             | File                                       | Runtime Path                               | Permissions |
| ------------------ | ------------------------------------------ | ------------------------------------------ | ----------- |
| Gateway token      | `secrets/hsb1-openclaw-gateway-token.age`  | `/run/agenix/hsb1-openclaw-gateway-token`  | 0400        |
| Telegram bot token | `secrets/hsb1-openclaw-telegram-token.age` | `/run/agenix/hsb1-openclaw-telegram-token` | 0400        |
| OpenRouter API key | `secrets/hsb1-openclaw-openrouter-key.age` | `/run/agenix/hsb1-openclaw-openrouter-key` | 0400        |

**Add to `secrets/secrets.nix`:**

```nix
"hsb1-openclaw-gateway-token.age".publicKeys = markus ++ hsb1;
"hsb1-openclaw-telegram-token.age".publicKeys = markus ++ hsb1;
"hsb1-openclaw-openrouter-key.age".publicKeys = markus ++ hsb1;
```

### 4. Host Integration Points

The AI will have access to:

| Capability        | Path/Command               | Use Case               |
| ----------------- | -------------------------- | ---------------------- |
| Docker management | `docker ps`, `docker logs` | Check container status |
| Home Assistant    | `http://localhost:8123`    | Automation management  |
| Node-RED          | `http://localhost:1880`    | Flow editing           |
| File editing      | `/home/mba/docker/mounts/` | Config modifications   |
| Systemctl         | `systemctl status/restart` | Service management     |
| ZFS               | `zpool status`             | Storage monitoring     |

## Implementation Tasks

### Phase 1: Foundation

- [x] Add `nix-openclaw` flake input to `flake.nix`
- [x] Update `overlays-local` to use upstream package
- [x] Remove vendored `pkgs/openclaw/` directory
- [ ] Add 3 secrets to `secrets/secrets.nix` (see Section 3)
- [ ] Create agenix secrets: `agenix -e secrets/hsb1-openclaw-*.age`
- [ ] Add OpenClaw systemd service to `hosts/hsb1/configuration.nix`

### Phase 2: Service & Config

- [ ] Define systemd service in configuration.nix (ExecStart, User, etc.)
- [ ] Generate openclaw.json via Nix (with `/run/agenix/` secret paths)
- [ ] Add age.secrets entries for the 3 secrets
- [ ] Configure sandboxing (Docker socket access for sandbox containers)
- [ ] Set up workspace directory (`/home/mba/.openclaw/workspace`)

### Phase 3: Channel Setup

- [ ] Create Telegram bot via @BotFather
- [ ] Configure Telegram channel in openclaw.json
- [ ] Test bot connectivity
- [ ] Set up pairing approval workflow

### Phase 4: LLM Integration

- [ ] Add OpenRouter API key to agenix
- [ ] Configure OpenRouter provider
- [ ] Test basic chat functionality
- [ ] Verify Kimi K2.5 responses

### Phase 5: Host Tools & Skills

- [ ] Create custom skill: "docker-status" (list containers)
- [ ] Create custom skill: "ha-restart" (restart Home Assistant)
- [ ] Create custom skill: "zfs-status" (check ZFS pool)
- [ ] Test file editing in docker mounts
- [ ] Verify browser automation capability

### Phase 6: Security Hardening

- [ ] Review sandbox configuration
- [ ] Test group chat isolation
- [ ] Verify personal DM full access
- [ ] Document security model in RUNBOOK

### Phase 7: Documentation & Handoff

- [ ] Update `hosts/hsb1/README.md` with OpenClaw section (port 18789, service)
- [ ] Add OpenClaw section to `hosts/hsb1/docs/RUNBOOK.md` (start/stop/debug)
- [ ] Document common commands and troubleshooting in RUNBOOK

## Testing Plan

| Test           | Command/Action                     | Expected Result             |
| -------------- | ---------------------------------- | --------------------------- |
| Service start  | `systemctl start openclaw-gateway` | Gateway listening on :18789 |
| Health check   | `openclaw health`                  | All green                   |
| Telegram DM    | Send "hello" to bot                | Response from Kimi K2.5     |
| Docker command | "show docker containers"           | Lists all containers        |
| File edit      | "edit homeassistant config"        | Opens file in workspace     |
| Sandbox test   | Add bot to group, send command     | Runs in isolated container  |

## Rollback Plan

1. **Service stop**: `systemctl stop openclaw-gateway`
2. **Disable**: Comment out/remove OpenClaw service section from `configuration.nix`
3. **Rebuild**: `just switch`
4. **Cleanup** (optional): `rm -rf ~/.openclaw/` (preserves workspace if needed later)

## Risk Assessment

| Risk              | Likelihood | Impact | Mitigation                           |
| ----------------- | ---------- | ------ | ------------------------------------ |
| LLM API costs     | Medium     | Low    | Monitor usage, set limits            |
| Telegram bot spam | Medium     | Medium | Pairing approval required            |
| Sandbox escape    | Low        | High   | Docker security, read-only root      |
| Service conflicts | Low        | Medium | Port 18789 check, isolated workspace |

## References

- **Host**: `hsb1` (192.168.1.101)
- **OpenClaw Docs**: https://docs.openclaw.ai/
- **Sandboxing**: https://docs.openclaw.ai/gateway/sandboxing
- **Architecture**: https://docs.openclaw.ai/concepts/architecture
- **Hetzner Guide**: https://docs.openclaw.ai/platforms/hetzner (for Docker reference)
- **Existing Backup**: Snapshot `5f1e7fa7` (Jan 31, 2026)
- **Related**: P7200 (Docker restructure), P9300 (VLC kiosk)

## Notes

- **Model Choice**: Kimi K2.5 via OpenRouter balances capability and cost
- **Workspace Location**: `/home/mba/.openclaw/workspace` (ZFS-backed via zroot/home)
- **Log Location**: `journalctl -u openclaw-gateway -f`
- **Monitoring**: Consider adding to Uptime Kuma (csb1) after deployment
- **Secrets Pattern**: Uses standard agenix `/run/agenix/` path (not `/etc/secrets/`)
- **Docker**: Enabled via hokage module (`role = "server-home"`); verify mba in docker group
