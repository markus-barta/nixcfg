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

- Auto-generates RSA-2048 self-signed cert, valid 10 years (`-days 3650`) — zero maintenance
- Cert stored in persistent data volume (`/var/lib/openclaw-gateway/data/gateway/tls/`) — survives restarts
- Trust model: SHA-256 **fingerprint pinning** (not CA chain) — browser shows cert warning on first visit only
- Switches gateway WebSocket to `wss://`

**Sources:**

- OpenClaw 2026.3.2 CHANGELOG: `/usr/local/lib/node_modules/openclaw/CHANGELOG.md` (inside container)
- TLS implementation source: `/usr/local/lib/node_modules/openclaw/dist/call-DaJKh-6e.js` (`#region src/infra/tls/gateway.ts`)

## Implementation

### Step 1 — Enable TLS (done: see commit after this backlog item)

`hosts/hsb0/docker/openclaw-gateway/openclaw.json`:

```json
"gateway": {
  "tls": { "enabled": true },
  "remote": { "url": "wss://100.64.0.6:18789" }
}
```

`hosts/miniserver-bp/docker/openclaw-percaival/openclaw.json`: same with `wss://100.64.0.10:18789`

- [x] Add `gateway.tls.enabled: true` to hsb0 openclaw.json
- [x] Add `gateway.tls.enabled: true` to miniserver-bp openclaw.json
- [x] Update `gateway.remote.url` to `wss://` on both hosts

### Step 2 — First boot (Markus runs on both hosts)

```bash
# On hsb0:
ssh mba@hsb0.lan
cd /opt/openclaw-gateway
docker compose up --force-recreate -d

# Read fingerprint from logs:
docker logs openclaw-gateway 2>&1 | grep -i "tls\|fingerprint\|cert"
```

Note the SHA-256 fingerprint output.

### Step 3 — Add fingerprint to config (Markus provides fingerprint → agent updates config)

`openclaw.json` update:

```json
"gateway": {
  "tls": { "enabled": true },
  "remote": {
    "url": "wss://100.64.0.6:18789",
    "tlsFingerprint": "<sha256-from-logs>"
  }
}
```

- [ ] Markus provides fingerprint from hsb0 logs
- [ ] Markus provides fingerprint from miniserver-bp logs
- [ ] Agent updates both openclaw.json files with tlsFingerprint
- [ ] Commit + push
- [ ] Markus runs `--force-recreate` again on both hosts

### Step 4 — Verify

- [ ] `https://100.64.0.6:18789` loads (cert warning expected — click "proceed anyway" once per browser profile)
- [ ] Device pairing works (no "requires secure context" error)
- [ ] `https://100.64.0.10:18789` same for miniserver-bp

## Acceptance Criteria

- [ ] Control UI accessible at `https://hsb0.lan:18789` and `https://100.64.0.6:18789`
- [ ] Device identity storage works (no browser secure context errors)
- [ ] CLI inside container connects via `wss://` with fingerprint pinning
- [ ] Zero maintenance — cert valid 10 years, auto-persisted in volume

## Notes

- **Chicken-and-egg**: fingerprint only known after first boot generates cert. Boot once → read fingerprint → add to config → restart.
- `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1` still set in docker-compose env — harmless with TLS enabled, can be removed post-verification.
- hsb0 has no reverse proxy (Traefik/Caddy/nginx) — direct TLS is the only viable approach without new services.
- Tailscale IPs: hsb0=`100.64.0.6`, miniserver-bp=`100.64.0.10` (Headscale, not official Tailscale — no `tailscale serve`/`funnel`).
