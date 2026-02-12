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

### 5. Use `--network=host` + `bind=auto` (required)

OpenClaw's security model: loopback = trusted (no pairing), anything else = external (pairing required). This is by design.

With default Docker bridge networking, the embedded agent connects to the gateway via the container's bridge IP (e.g. `172.17.0.3`), which the gateway treats as external.

**The fix: `--network=host` + `gateway.bind: "auto"`**. The container shares the host's network stack. The `auto` bind mode tries loopback first, falling back to LAN. Combined with host networking, this gives us:

- Internal agent runtime (cron, tools, Telegram) → connects via loopback → trusted
- External access (Control UI from browser) → accessible on LAN IP (`10.17.1.40:18789`)

```nix
virtualisation.oci-containers.containers.openclaw-percaival = {
  image = "openclaw-percaival:latest";
  extraOptions = [ "--network=host" ];
  volumes = [ "/var/lib/openclaw-percaival/data:/home/node/.openclaw:rw" ];
  autoStart = true;
};
```

In `openclaw.json`:

```json5
{ gateway: { bind: "auto" } }
```

**Quirk**: Even with this setup, `docker exec openclaw-percaival openclaw devices list` (and other CLI RPC commands) still fail with "pairing required". This is because the CLI connects to the gateway via a separate WebSocket RPC path that enforces device pairing regardless of loopback.

However, the **actual agent runtime works fine**: the embedded agent, cron scheduler, Telegram channel, and internal tools all operate in-process and don't go through the RPC pairing layer. `openclaw doctor` also works.

**What works:**

- Telegram DMs and group chat
- Cron jobs
- Internal tools
- `openclaw doctor`
- Control UI from browser (with `allowInsecureAuth`)

**What doesn't work (cosmetic):**

- `openclaw devices list` — "pairing required" via RPC
- `openclaw gateway status` — RPC probe fails (but shows correct config)
- Other CLI RPC commands that connect via WebSocket

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

### 11. npm install vs official Dockerfile — open investigation

Our approach (`npm install -g openclaw@latest` in a slim image) causes device pairing issues because the npm CLI package connects to the gateway via the container's LAN IP, which the gateway treats as external.

The official repo Dockerfile uses a full `pnpm build` from source and may handle internal connections differently. The official `docker-setup.sh` script may also configure the container to avoid this. **This needs further investigation** — see "Known Issues" section below.

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

## Files

| What                       | Where                                                                          |
| -------------------------- | ------------------------------------------------------------------------------ |
| Dockerfile                 | `hosts/miniserver-bp/docker/Dockerfile`                                        |
| NixOS config               | `hosts/miniserver-bp/configuration.nix` (lines 215-226, 240-256)               |
| Config (host)              | `/var/lib/openclaw-percaival/data/openclaw.json`                               |
| Workspace (host)           | `/var/lib/openclaw-percaival/data/workspace/`                                  |
| Agenix secret              | `secrets/miniserver-bp-openclaw-telegram-token.age`                            |
| Backlog item               | `hosts/miniserver-bp/docs/backlog/P80--5c21a08--install-openclaw-percaival.md` |
| Container logs             | `docker logs openclaw-percaival`                                               |
| Gateway log (in container) | `/tmp/openclaw/openclaw-YYYY-MM-DD.log`                                        |

## Network

| Port  | Service            | Firewall |
| ----- | ------------------ | -------- |
| 2222  | SSH                | Open     |
| 8888  | pm-tool            | Open     |
| 18789 | OpenClaw Percaival | Open     |

## Investigation Log: Docker Bridge vs Loopback

This section documents the pairing issue we hit and what we tried, for future reference.

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
| `openclaw devices approve` (Grok's suggestion)         | Chicken-and-egg: CLI itself needs gateway access to approve |
| Official repo Dockerfile / `docker-setup.sh`           | Same gateway auth logic, doesn't change loopback behavior   |
| `--network=host` + `bind=lan`                          | Agent still connects via host LAN IP (10.17.1.40)           |
| `--network=host` + `bind=auto` for CLI RPC             | Loopback works but CLI RPC still requires pairing (see #5)  |

### What works

**`--network=host` + `bind=auto`** — container shares host network stack. `auto` bind mode tries loopback first. The in-process agent runtime (cron, Telegram, tools) works because it doesn't go through the RPC pairing layer. See gotcha #5.

**Remaining quirk**: CLI RPC commands (`openclaw devices list`, `openclaw gateway status`) still fail with "pairing required" even on loopback. This appears to be a separate pairing layer for WebSocket RPC that is enforced regardless of source IP. The `openclaw doctor` command works because it reads state directly. This doesn't affect actual agent functionality — it's cosmetic.

### Pairing architecture (what we learned)

OpenClaw has two distinct connection paths:

1. **In-process agent runtime** — the embedded agent, cron scheduler, and channel connectors (Telegram, etc.) run inside the gateway process. Not subject to device pairing. This is why cron and Telegram work.

2. **CLI RPC commands** — `openclaw devices list`, `openclaw gateway status`, etc. connect via WebSocket RPC. This path enforces device pairing even on loopback. `openclaw doctor` is an exception (reads state directly, no RPC).

The "pairing required" on loopback for CLI RPC may be a bug, a v2026.2.9 behavior change, or undocumented. For practical purposes it doesn't matter — the agent runtime works without CLI RPC.

## Deployment Approach Comparison

| Approach                                                   | Pros                  | Cons                                           | Status                           |
| ---------------------------------------------------------- | --------------------- | ---------------------------------------------- | -------------------------------- |
| **Option A**: Official Dockerfile (full repo build)        | Official              | Heavy build, slow updates, same auth logic     | Not viable (doesn't fix pairing) |
| **Option B**: npm install + `--network=host` + `bind=auto` | Simple, fast, working | Reduced network isolation, CLI RPC broken      | **In use, working**              |
| **Option C**: Nix package + systemd                        | No container overhead | Brittle, constant patching, npm sandbox breaks | Tested on hsb1 — not recommended |

## References

- Docs: https://docs.openclaw.ai/
- Docker install: https://docs.openclaw.ai/install/docker
- Config reference: https://docs.openclaw.ai/gateway/configuration
- Health check: https://docs.openclaw.ai/gateway/health
- Troubleshooting: https://docs.openclaw.ai/gateway/troubleshooting
