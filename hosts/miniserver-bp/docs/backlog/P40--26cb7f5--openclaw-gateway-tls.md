# openclaw-gateway-tls

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-03-07

---

## Problem

Same root cause as hsb0 (see `hosts/hsb0/docs/backlog/P40--61d31d9--openclaw-gateway-tls.md`).
OpenClaw 2026.3.2 requires HTTPS for Control UI device identity storage.
`gateway.tls.enabled: true` was added but the setup is not yet complete.

## Current State (as of 2026-03-07)

- `gateway.tls.enabled: true` ✅ already in `openclaw.json`
- `gateway.bind: "tailnet"` ✅
- `gateway.remote.url: "wss://100.64.0.10:18789"` ✅
- `OPENCLAW_GATEWAY_URL=wss://100.64.0.10:18789` ✅ added to `docker-compose.yml`
- **TLS fingerprint**: NOT YET added — container was unreachable at time of hsb0 work
- **Device pairing**: NOT YET approved

## Solution

Same as hsb0: extract TLS fingerprint → add to config → `--force-recreate` → approve device pairing.

## Implementation

### Step 1 — Extract TLS fingerprint

SSH is currently unreachable from macOS (`10.17.1.40:2222` times out). Once available:

```bash
ssh -p 2222 mba@10.17.1.40 \
  "docker logs openclaw-percaival 2>&1 | grep -i 'fingerprint\|SHA'"
# OR read cert directly:
ssh -p 2222 mba@10.17.1.40 \
  "docker exec openclaw-percaival sh -c \
  'openssl x509 -in /home/node/.openclaw/gateway/tls/gateway-cert.pem -fingerprint -sha256 -noout'"
```

- [ ] SSH access restored / confirmed
- [ ] TLS fingerprint extracted

### Step 2 — Add fingerprint to config

Update `hosts/miniserver-bp/docker/openclaw-percaival/openclaw.json`:

```json
"remote": {
  "url": "wss://100.64.0.10:18789",
  "tlsFingerprint": "<sha256-from-step-1>"
}
```

- [ ] `tlsFingerprint` added, committed, pushed

### Step 3 — Deploy + approve device

```bash
ssh -p 2222 mba@10.17.1.40 \
  "cd ~/Code/nixcfg/hosts/miniserver-bp/docker && git pull && docker compose up --force-recreate -d openclaw-percaival"

# Open browser → https://100.64.0.10:18789 → accept cert warning
# Then approve:
ssh -p 2222 mba@10.17.1.40 \
  "docker exec openclaw-percaival openclaw devices list"
ssh -p 2222 mba@10.17.1.40 \
  "docker exec openclaw-percaival openclaw devices approve <requestId>"
```

- [ ] `--force-recreate` run
- [ ] CLI works (`openclaw devices list` succeeds)
- [ ] Browser device approved

### Step 4 — Cleanup

- [ ] `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1` removed from `docker-compose.yml`
- [ ] Control UI accessible at `https://100.64.0.10:18789`
- [ ] Backlog item marked Done

## Acceptance Criteria

- [ ] Control UI at `https://100.64.0.10:18789` connects and works
- [ ] CLI inside container functional
- [ ] Zero maintenance

## Notes

- SSH: `ssh -p 2222 mba@10.17.1.40`
- Container: `openclaw-percaival`
- Data volume: `/var/lib/openclaw-percaival/data/`
- Tailscale IP: `100.64.0.10`
- Headscale — no `tailscale serve`/`funnel`
- Reference: `hosts/hsb0/docs/backlog/P40--61d31d9--openclaw-gateway-tls.md` (completed first)
