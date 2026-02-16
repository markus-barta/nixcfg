# agent-to-agent-comms-opencode-percy

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-16

---

## Problem

Markus has to manually copy-paste messages between OpenCode (CLI agent) and Percy (OpenClaw/Telegram agent). Tedious, error-prone, slow.

Constraints:

- Percy lives on Telegram (@percaival_bot)
- OpenCode is a CLI agent (no Telegram access)
- Markus wants read-visibility on the conversation
- Should NOT require Markus to type messages on behalf of either agent
- Percy can't message himself (Telegram bot limitation)

## Solution

Investigate these approaches (in priority order):

1. **OpenClaw Gateway API** — Check if port 18789 exposes an HTTP API for programmatic message injection. Cleanest path; avoids Telegram entirely. Markus reads via Control UI or logs.
2. **Telegram group + relay bot** — Create a shared Telegram group. A second lightweight bot (curl-able from CLI) relays OpenCode messages. Percy sees and responds in the group. Markus reads everything there.
3. **OpenClaw agent-to-agent** — If OpenClaw supports `tools.agentToAgent` cross-agent messaging, could a second OpenClaw agent act as the bridge?

## Implementation

- [ ] Research OpenClaw gateway API (docs, `/health` endpoint, WebSocket protocol)
- [ ] Test if gateway accepts injected messages via HTTP POST
- [ ] If not: evaluate Telegram relay bot approach
- [ ] Implement chosen approach
- [ ] Documentation update (OPENCLAW-RUNBOOK.md)

## Acceptance Criteria

- [ ] OpenCode can send a message that Percy receives and responds to
- [ ] Markus can read both sides of the conversation without copy-pasting
- [ ] No manual intermediary steps required

## Notes

- OpenClaw gateway runs on `http://10.17.1.40:18789`
- OpenClaw multi-agent docs mention `tools.agentToAgent` — could be relevant
- Percy's m365-email skill already shows OpenClaw can integrate external tools
