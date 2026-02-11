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

### 5. Gateway must bind to 0.0.0.0 inside container

Loopback (127.0.0.1) won't work — Docker port forwarding needs the container to listen on all interfaces.

During onboard wizard, select: **LAN (0.0.0.0)**

### 6. Control UI requires HTTPS — or `allowInsecureAuth`

Accessing `http://10.17.1.40:18789/#token=...` fails with:

```
disconnected (1008): control ui requires HTTPS or localhost (secure context)
```

Fix: add to `openclaw.json`:

```json5
{
  gateway: {
    controlUi: {
      allowInsecureAuth: true,
    },
  },
}
```

Acceptable for office LAN test server. For production, use Tailscale Serve or a reverse proxy with TLS.

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

### 10. Tailscale exposure — skip for now

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

## References

- Docs: https://docs.openclaw.ai/
- Docker install: https://docs.openclaw.ai/install/docker
- Config reference: https://docs.openclaw.ai/gateway/configuration
- Health check: https://docs.openclaw.ai/gateway/health
- Troubleshooting: https://docs.openclaw.ai/gateway/troubleshooting
