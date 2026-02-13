# install-openclaw-percaival

**Host**: miniserver-bp
**Priority**: P80
**Status**: Done
**Created**: 2026-02-10
**Updated**: 2026-02-11

---

## Problem

Need OpenClaw AI agent on miniserver-bp with identity "Percaival" (nicknames: Percai/Percy) for testing and experimentation via Telegram.

## Solution

Deploy OpenClaw via a custom Docker image (`FROM node:22-bookworm-slim` + `npm install -g openclaw@latest`) on miniserver-bp. Use the existing `virtualisation.oci-containers` pattern (same as pm-tool). Agent identity and channel config via mounted `openclaw.json`.

## Prerequisites

- [x] Docker enabled: `virtualisation.oci-containers.backend = "docker"` (`configuration.nix:203`)
- [x] Existing oci-containers pattern: pm-tool on port 8888 (`configuration.nix:206-211`)
- [x] miniserver-bp host key in `secrets/secrets.nix:56-58` (needed for new agenix secrets)
- [x] mba uid = 1000 (`configuration.nix:155`) — matches container `node` user (uid 1000)
- [x] Telegram bot token (Markus creates via @BotFather, stores in 1Password)

## Implementation

### Phase 1: Docker Image

Create Dockerfile in nixcfg repo (follows fleet pattern: hsb0, hsb1, csb0 store Dockerfiles in git):

```dockerfile
# hosts/miniserver-bp/docker/Dockerfile
FROM node:22-bookworm-slim
RUN npm install -g openclaw@latest
EXPOSE 18789
CMD ["openclaw", "gateway", "--port", "18789"]
```

Build on miniserver-bp:

```bash
# SSH to miniserver-bp
ssh -p 2222 mba@10.17.1.40

# On miniserver-bp:
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker build -t openclaw-percaival:latest .
```

To update OpenClaw later: rebuild image with same command, then `docker restart docker-openclaw-percaival.service`.

### Phase 2: Prepare Secrets (requires Markus)

- [x] Create Telegram bot via @BotFather → get token
- [x] Create agenix secret: `agenix -e secrets/miniserver-bp-openclaw-telegram-token.age`
- [x] Add to `secrets/secrets.nix`:
  ```nix
  "miniserver-bp-openclaw-telegram-token.age".publicKeys = markus ++ miniserver-bp;
  ```
- [x] Rekey: `just rekey` (USER ONLY — do not run as agent)
- [x] Committed to git

### Phase 3: NixOS Configuration Changes

File: `hosts/miniserver-bp/configuration.nix`

**3a. Add agenix secret declaration** (after line 80):

```nix
age.secrets.miniserver-bp-openclaw-telegram-token.file = ../../secrets/miniserver-bp-openclaw-telegram-token.age;
```

**3b. Add container** (after pm-tool container block, ~line 211):

```nix
virtualisation.oci-containers.containers.openclaw-percaival = {
  image = "openclaw-percaival:latest";
  ports = [ "18789:18789" ];
  volumes = [
    "/var/lib/openclaw-percaival/data:/home/node/.openclaw:rw"
  ];
  environment = {
    TELEGRAM_BOT_TOKEN = ""; # placeholder — will be overridden by environmentFiles
  };
  environmentFiles = [
    # agenix decrypts to /run/agenix/miniserver-bp-openclaw-telegram-token
    # Format inside file: just the raw token value
    # NOTE: environmentFiles expects KEY=VALUE format. If agenix file is raw token,
    # use a wrapper script instead. See open question #2.
  ];
  autoStart = true;
};
```

**3c. Add firewall port** (after line 231):

```nix
allowedTCPPorts = [
  2222  # SSH
  8888  # pm-tool
  18789 # OpenClaw Percaival
];
```

**3d. Add activation script** for data directory (after pm-tool activation, ~line 222):

```nix
system.activationScripts.openclaw-percaival = ''
  mkdir -p /var/lib/openclaw-percaival/data
  chown -R 1000:1000 /var/lib/openclaw-percaival/data
'';
```

**3e. Create openclaw.json** at `/var/lib/openclaw-percaival/data/openclaw.json`:

```json5
{
  gateway: {
    port: 18789,
    bind: "0.0.0.0",
  },
  agents: {
    defaults: {
      workspace: "/home/node/.openclaw/workspace",
    },
    list: [
      {
        id: "main",
        identity: {
          name: "Percaival",
          theme: "helpful medieval knight",
          emoji: "⚔️",
        },
        groupChat: {
          mentionPatterns: ["@Percaival", "@Percai", "@Percy", "Percaival"],
        },
      },
    ],
  },
  channels: {
    telegram: {
      enabled: true,
      // botToken injected via TELEGRAM_BOT_TOKEN env var
      dmPolicy: "pairing",
    },
  },
}
```

### Phase 4: Deploy

Cannot build NixOS on macOS. SSH to miniserver-bp:

```bash
# From mba-imac-work (office LAN — miniserver-bp is reachable)
ssh -p 2222 mba@10.17.1.40

# On miniserver-bp:
cd ~/Code/nixcfg && git pull
sudo nixos-rebuild switch --flake .#miniserver-bp
```

### Phase 5: First-Run Setup (interactive)

After container starts, onboard wizard is needed once:

```bash
# On miniserver-bp:
docker exec -it docker-openclaw-percaival.service openclaw onboard
# OR (if systemd container naming):
docker exec -it $(docker ps -q -f name=openclaw-percaival) openclaw onboard
```

### Phase 6: Verify + Document

- [x] `docker ps | grep openclaw` — container running
- [x] `curl http://10.17.1.40:18789/` — Control UI responds
- [x] Send Telegram DM to bot → receive pairing code
- [x] Approve pairing: `docker exec ... openclaw pairing approve telegram <code>`
- [x] Send test message → "Percaival" responds
- [x] Update `hosts/miniserver-bp/README.md` — add OpenClaw to services table
- [x] Update `hosts/miniserver-bp/docs/RUNBOOK.md` — add ops procedures

## Acceptance Criteria

- [x] OpenClaw Docker container running on miniserver-bp
- [x] Agent identity is "Percaival" (verified in Telegram)
- [x] Container auto-starts on boot (`autoStart = true`)
- [x] `docker ps` shows openclaw-percaival container
- [x] Control UI accessible at `http://10.17.1.40:18789/`
- [x] Telegram DM pairing works
- [x] README.md updated with OpenClaw service entry + port 18789
- [x] RUNBOOK.md updated with container ops (restart, logs, update)

## Open Questions

1. **Onboard wizard scope**: Does `openclaw onboard --install-daemon` try to install a systemd user service inside the container? If so, skip `--install-daemon` flag (NixOS manages the container lifecycle). Likely just `openclaw onboard` is sufficient.
2. **Agenix + env var injection**: Agenix decrypts to a file with raw content (no KEY=VALUE). `environmentFiles` in oci-containers expects `KEY=VALUE` format. Options:
   - **A)** Write a wrapper activation script that creates `/var/lib/openclaw-percaival/env` with `TELEGRAM_BOT_TOKEN=<content of agenix file>`
   - **B)** Put botToken directly in `openclaw.json` using a templated activation script
   - **C)** Use `environment.TELEGRAM_BOT_TOKEN` with a hardcoded value (less secure but simpler for test server)
   - Recommendation: **A** — small activation script, keeps secret out of nix store
3. **Gateway bind `0.0.0.0`**: Required inside container for port forwarding to work. Docs warn this disables Tailscale Serve integration — acceptable since we're on office LAN.
4. **Container name**: NixOS oci-containers creates systemd service `docker-openclaw-percaival.service`. The Docker container name may differ. Verify after first deploy.

## References

| What                       | Where                                                          |
| -------------------------- | -------------------------------------------------------------- |
| OpenClaw Docs              | https://docs.openclaw.ai/                                      |
| OpenClaw GitHub            | https://github.com/openclaw/openclaw                           |
| Docker Install Guide       | https://docs.openclaw.ai/install/docker                        |
| Config Reference           | https://docs.openclaw.ai/gateway/configuration                 |
| Existing container pattern | `hosts/miniserver-bp/configuration.nix:203-211`                |
| Secrets config             | `secrets/secrets.nix:56-58` (miniserver-bp host key)           |
| Host README                | `hosts/miniserver-bp/README.md`                                |
| Host RUNBOOK               | `hosts/miniserver-bp/docs/RUNBOOK.md`                          |
| hsb1 OpenClaw backlog      | `hosts/hsb1/docs/backlog/P94--0e9a020--openclaw-deployment.md` |
| Nix package (not used)     | `pkgs/openclaw/package.nix` (v2026.2.3)                        |

## Notes

- **Host**: miniserver-bp (10.17.1.40) — BYTEPOETS office test server
- **SSH**: `ssh -p 2222 mba@10.17.1.40` (from office LAN)
- **SSH (mDNS)**: `ssh mba@miniserver-bp.local` (also port 2222 via hokage server-remote)
- **Criticality**: 🟢 LOW (non-production test environment)
- **Risk**: 🟢 LOW — isolated container, no production dependencies
- **Build host**: Cannot build on macOS. SSH to miniserver-bp directly (it's a NixOS host, can self-build). Alternative: gpc0 for faster builds.
- **Docker container user**: `node` (uid 1000) — matches `mba` uid on miniserver-bp, so volume permissions are fine without special handling
- **Update path**: Rebuild Docker image with `docker build`, then restart container
