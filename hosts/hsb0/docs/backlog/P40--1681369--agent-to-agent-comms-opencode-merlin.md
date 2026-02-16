# agent-to-agent-comms-opencode-merlin

**Host**: hsb0
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-16

---

## Problem

Markus has to manually copy-paste messages between OpenCode (CLI agent) and Merlin (OpenClaw agent on hsb0). Tedious, error-prone, slow.

Constraints:

- Merlin lives on hsb0 (`192.168.1.99:18789`, OpenClaw gateway)
- OpenCode is a CLI agent running on macOS (imac0 or mba-mbp-work)
- Markus wants read-visibility on the conversation (Control UI or logs)
- Should NOT require Markus to type messages on behalf of either agent

## Options Evaluated

### Option A: HTTP Webhook (one-way)

`POST /hooks/agent` with Bearer token. Simple curl call, returns 202 async.

```bash
curl -X POST http://192.168.1.99:18789/hooks/agent \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello from OpenCode"}'
```

**Pro**: Dead simple, one curl call.
**Con**: One-way only — can send but can't receive Merlin's response programmatically. No real-time streaming. OpenCode would be blind to replies.

**Verdict**: Insufficient. Need two-way comms.

### Option B: WebSocket Full-Duplex (chosen)

Connect to gateway WS, complete challenge-response handshake, send `agent` requests, stream back `event:agent` responses in real-time.

**Pro**: Full two-way comms. OpenCode sends AND receives. Real-time streaming.
**Con**: More complex — needs handshake, auth, event parsing. Requires a bridge script.

**Verdict**: Best fit. Detailed spec below.

### Option C: `sessions_send` Agent-to-Agent (built-in)

OpenClaw's built-in session tools (`sessions_send`, `sessions_list`, `sessions_history`). Would require running a bridge agent on hsb0 that OpenCode communicates with.

**Pro**: Cleanest architecture long-term. Built-in reply-back loop (up to 5 ping-pong turns). Messages tagged with `provenance.kind = "inter_session"`.
**Con**: Requires deploying a second OpenClaw agent on hsb0 (Crown Jewel). Heaviest setup. Overkill for current needs.

**Verdict**: Future upgrade path if Option B proves limiting.

## Solution (Option B — WebSocket)

Python bridge script on macOS connects to Merlin's gateway via WebSocket. OpenCode calls the script to send messages and read responses. Markus watches via Control UI.

### Protocol Detail

#### 1. Connect & Handshake

Gateway sends challenge on connect:

```json
{
  "type": "event",
  "event": "connect.challenge",
  "payload": { "nonce": "...", "ts": 1737264000000 }
}
```

Client must respond with `connect` request:

```json
{
  "type": "req",
  "id": "connect-1",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "opencode-bridge",
      "version": "0.1.0",
      "platform": "macos",
      "mode": "operator"
    },
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],
    "caps": [],
    "commands": [],
    "permissions": {},
    "auth": { "token": "GATEWAY_TOKEN_HERE" },
    "locale": "en-US",
    "userAgent": "opencode-bridge/0.1.0"
  }
}
```

Gateway responds:

```json
{
  "type": "res",
  "id": "connect-1",
  "ok": true,
  "payload": {
    "type": "hello-ok",
    "protocol": 3,
    "policy": { "tickIntervalMs": 15000 }
  }
}
```

#### 2. Send Message

```json
{
  "type": "req",
  "id": "msg-001",
  "method": "agent",
  "params": {
    "message": "Your message from OpenCode here"
  }
}
```

Gateway acks immediately:

```json
{
  "type": "res",
  "id": "msg-001",
  "ok": true,
  "payload": { "status": "accepted", "runId": "run_abc123" }
}
```

#### 3. Receive Streamed Response

Multiple `event:agent` events arrive with partial/streaming content, then a final response:

```json
{
  "type": "res",
  "id": "msg-001",
  "ok": true,
  "payload": { "runId": "run_abc123", "status": "ok", "summary": "..." }
}
```

#### 4. Keepalive

Gateway expects periodic ticks (per `tickIntervalMs` in hello-ok). Client must respond to stay connected.

### Bridge Script Design

**Language**: Python (websockets library)
**Location**: `scripts/merlin-bridge.py` (in nixcfg repo)
**Dependencies**: `pip install websockets` (or nix shell)

**Modes**:

- `--send "message"` — Connect, handshake, send, wait for full response, print, disconnect
- `--interactive` — Stay connected, read stdin, print responses (for OpenCode tool use)
- `--listen` — Connect read-only, print all agent events (monitoring)

**Auth**: Read gateway token from env var `MERLIN_GATEWAY_TOKEN` (Markus sets from 1Password or agenix-decrypted file).

**Output format**: JSON lines to stdout (parseable by OpenCode). Stderr for connection/debug info.

```
# Usage examples:
export MERLIN_GATEWAY_TOKEN=$(ssh mba@hsb0.lan "cat /run/agenix/hsb0-openclaw-gateway-token")
python scripts/merlin-bridge.py --send "What's the current home temperature?"
python scripts/merlin-bridge.py --interactive
```

## Implementation

- [ ] Write `scripts/merlin-bridge.py` with connect/handshake logic
- [ ] Implement `--send` mode (single message, wait for response, exit)
- [ ] Implement `--interactive` mode (stdin loop, streaming responses)
- [ ] Implement `--listen` mode (read-only event monitor)
- [ ] Test health check: `curl http://192.168.1.99:18789/health`
- [ ] Test WS handshake with real gateway token
- [ ] Send test message, verify Merlin responds
- [ ] Verify conversation visible in Control UI
- [ ] Handle edge cases: auth failure, timeout, reconnect, gateway restart
- [ ] Document in OPENCLAW-RUNBOOK.md (new "Bridge / Programmatic Access" section)

## Acceptance Criteria

- [ ] OpenCode can send a message that Merlin receives and responds to
- [ ] OpenCode can read Merlin's full response (not just fire-and-forget)
- [ ] Markus can watch both sides via Control UI without intervention
- [ ] No manual intermediary steps required
- [ ] Bridge script handles auth, reconnect, and timeouts gracefully
- [ ] Works from imac0 and mba-mbp-work (home LAN)

## Notes

- Gateway endpoint: `ws://192.168.1.99:18789`
- Health check: `curl http://192.168.1.99:18789/health`
- Gateway token on host: `/run/agenix/hsb0-openclaw-gateway-token`
- hsb0 is Crown Jewel — bridge is read/write via WS only, no host changes needed
- Device pairing: first connect from new client ID may require approval in Control UI
- Protocol version 3 is current (check docs.openclaw.ai for updates)
- Ref docs: docs.openclaw.ai/gateway/protocol, docs.openclaw.ai/automation/webhook
