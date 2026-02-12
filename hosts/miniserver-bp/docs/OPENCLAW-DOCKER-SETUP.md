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

### Web Search (Brave Search)

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

**`--network=host` + `bind=lan`** — container shares host network stack. The in-process agent runtime (cron, Telegram, tools) works because it doesn't go through the RPC pairing layer. `bind=lan` keeps the Control UI accessible from the office LAN. See gotcha #5.

We also tested `bind=auto` (loopback only) — agent runtime also works, but Control UI becomes inaccessible from LAN. `bind=lan` is the better choice.

**Remaining quirk**: CLI RPC commands (`openclaw devices list`, `openclaw gateway status`) still fail with "pairing required" even on loopback. This appears to be a separate pairing layer for WebSocket RPC that is enforced regardless of source IP. The `openclaw doctor` command works because it reads state directly. This doesn't affect actual agent functionality — it's cosmetic.

### Pairing architecture (what we learned)

OpenClaw has two distinct connection paths:

1. **In-process agent runtime** — the embedded agent, cron scheduler, and channel connectors (Telegram, etc.) run inside the gateway process. Not subject to device pairing. This is why cron and Telegram work.

2. **CLI RPC commands** — `openclaw devices list`, `openclaw gateway status`, etc. connect via WebSocket RPC. This path enforces device pairing even on loopback. `openclaw doctor` is an exception (reads state directly, no RPC).

The "pairing required" on loopback for CLI RPC may be a bug, a v2026.2.9 behavior change, or undocumented. For practical purposes it doesn't matter — the agent runtime works without CLI RPC.

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
