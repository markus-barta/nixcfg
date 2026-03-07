# openclaw-gateway-tls

**Host**: hsb0 (also affects miniserver-bp)
**Priority**: P40
**Status**: In Progress
**Created**: 2026-03-07

---

## Problem

OpenClaw Control UI (`http://hsb0.lan:18789`, `http://100.64.0.6:18789`) is broken because:

1. OpenClaw 2026.3.2 hardened `ws://` to loopback-only by default — non-loopback WebSocket requires `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1`
2. Even with that env var, **browsers refuse device identity storage on HTTP** — the Control UI uses `crypto`/`storage` APIs that require a **secure context** (HTTPS or localhost)
3. `dangerouslyDisableDeviceAuth` no longer bypasses device auth for non-loopback origins in 2026.3.2 — removed

The correct fix is `gateway.tls.enabled: true` — OpenClaw's built-in self-signed TLS.

## Solution

Enable OpenClaw's built-in self-signed TLS (`gateway.tls.enabled: true`).

- Auto-generates RSA-2048 self-signed cert, valid 10 years — zero maintenance
- Cert stored in persistent data volume (`/var/lib/openclaw-gateway/data/gateway/tls/`) — survives restarts
- Trust model: SHA-256 **fingerprint pinning** — browser shows cert warning on first visit only
- Switches gateway WebSocket to `wss://`

Both hosts use Headscale (not official Tailscale) — `tailscale serve`/`funnel` not available.
`gateway.bind: "tailnet"` is the correct approach: binds to the Tailscale IP only.

**Important: `bind: "tailnet"` means loopback (`127.0.0.1`) does NOT work.**
The CLI inside the container must use `gateway.remote.url` + `gateway.remote.tlsFingerprint`
so it connects via `wss://100.64.x.x:18789` instead of the default loopback target.

**Device pairing**: remote (tailnet) connections require one-time CLI approval.
Flow: open browser → "pairing required" → `openclaw devices list` → `openclaw devices approve <id>` → done.

**Sources:**

- OpenClaw 2026.3.2 CHANGELOG: `/usr/local/lib/node_modules/openclaw/CHANGELOG.md` (inside container)
- TLS implementation source: `/usr/local/lib/node_modules/openclaw/dist/call-DaJKh-6e.js` (`#region src/infra/tls/gateway.ts`)
- Docs: https://docs.openclaw.ai/gateway/tailscale, https://docs.openclaw.ai/web/control-ui

## Implementation

### Step 1 — Enable TLS ✅ (commits `4982e55c`, `a9452648`)

- [x] `gateway.tls.enabled: true` on both hosts
- [x] `gateway.remote.url` → `wss://` on both hosts
- [x] `allowedOrigins` → `https://` on both hosts
- [x] Removed `allowInsecureAuth` + `dangerouslyDisableDeviceAuth`
- [x] hsb0 `--force-recreate` run — gateway on `wss://100.64.0.6:18789` ✅

### Step 2 — TLS fingerprints

hsb0 fingerprint ✅ already in config:
`C9:78:34:30:4C:25:3D:D5:58:C0:C3:DE:05:62:F0:03:83:33:3B:AB:03:06:45:13:98:29:B6:23:83:12:A5:E3`

- [x] hsb0 `tlsFingerprint` added to `openclaw.json`
- [ ] miniserver-bp: extract fingerprint (see below)
- [ ] miniserver-bp: add `tlsFingerprint`, commit + push, `--force-recreate`

#### Extract miniserver-bp fingerprint

```bash
# Check RUNBOOK for miniserver-bp SSH details
docker logs openclaw-percaival 2>&1 | grep -i 'fingerprint\|SHA'
# OR:
docker exec openclaw-percaival sh -c \
  'openssl x509 -in /home/node/.openclaw/gateway/tls/gateway-cert.pem -fingerprint -sha256 -noout'
```

### Step 3 — Verify CLI works inside containers

With `gateway.remote.url` + `gateway.remote.tlsFingerprint` set, the CLI should
now connect via `wss://100.64.x.x:18789` instead of loopback.

```bash
ssh mba@hsb0.lan "docker exec openclaw-gateway openclaw devices list"
```

- [ ] `openclaw devices list` works on hsb0
- [ ] `openclaw devices list` works on miniserver-bp (after Step 2)

### Step 4 — Approve browser device pairing

```bash
# Open browser → https://100.64.0.6:18789 → accept cert warning
# Then approve the pending pairing request:
ssh mba@hsb0.lan "docker exec openclaw-gateway openclaw devices list"
ssh mba@hsb0.lan "docker exec openclaw-gateway openclaw devices approve <requestId>"
```

- [ ] Browser device approved on hsb0
- [ ] Browser device approved on miniserver-bp

### Step 5 — Final verification + cleanup

- [ ] `https://100.64.0.6:18789` Control UI loads and works
- [ ] `https://100.64.0.10:18789` Control UI loads and works
- [ ] Remove `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1` from both docker-compose files
- [ ] Mark backlog item Done

## Acceptance Criteria

- [ ] Control UI at `https://100.64.0.6:18789` (hsb0) — connects, no secure context errors
- [ ] Control UI at `https://100.64.0.10:18789` (miniserver-bp) — same
- [ ] CLI inside both containers functional (`openclaw devices list` works)
- [ ] Zero maintenance — cert valid 10 years, auto-persisted in volume

## Notes

- Both hosts use Headscale — no `tailscale serve`/`funnel`. Direct TLS bind only.
- `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1` harmless with TLS active; remove post-verification.
- Tailscale IPs: hsb0=`100.64.0.6`, miniserver-bp=`100.64.0.10`
- Containers: `openclaw-gateway` (hsb0), `openclaw-percaival` (miniserver-bp)
- Data volumes: `/var/lib/openclaw-gateway/data/`, `/var/lib/openclaw-percaival/data/`
- miniserver-bp SSH: check RUNBOOK (`.lan` DNS not resolving from macOS in current session)
