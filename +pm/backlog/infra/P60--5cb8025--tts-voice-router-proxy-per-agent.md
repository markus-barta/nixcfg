# TTS Voice Router Proxy — Per-Agent Deterministic Voice

**Priority**: P60
**Status**: Backlog
**Created**: 2026-02-28

---

## Problem

OpenClaw's `messages.tts` config is top-level only — no per-agent voice override exists in the schema. Current workaround uses `modelOverrides` + `[[tts:voiceId=...]]` directives in each agent's `SOUL.md`. This is fragile:

- Model may forget/ignore the directive
- Relies on LLM output for infrastructure behavior
- Violates separation of concerns: voice identity is not cognition, it's embodiment
- In principle vulnerable to prompt injection hijacking voice identity

## Solution

Insert a deterministic TTS routing proxy **inside the container** between OpenClaw and the ElevenLabs API:

```
OpenClaw → Voice Router (localhost) → ElevenLabs API
```

- Proxy listens on `localhost:<port>`
- `openclaw.json` sets `messages.tts.elevenlabs.baseUrl` to proxy URL
- Proxy intercepts TTS requests and substitutes correct `voiceId` based on agent routing
- `modelOverrides.enabled: false` — model cannot override voice

## Core Challenge

OpenClaw's ElevenLabs HTTP request does not include agent identity. The proxy must infer agent from request context (timing, session correlation, or a sidecar mechanism).

**Possible approaches:**

1. **Two proxy endpoints** — one per agent, each hardcoding a voiceId. OpenClaw would need per-agent `baseUrl` support (not yet available).
2. **Session-correlated routing** — proxy reads the active agent session from OpenClaw's RPC/state before forwarding. Adds latency but is agent-aware.
3. **Wait for native per-agent TTS** — OpenClaw adds `agents.list[].messages.tts` to schema (natural roadmap item). Proxy becomes unnecessary.

**Recommended approach when implementing:** Option 2 (session correlation) or wait for native support.

## Implementation

- [ ] Assess if OpenClaw adds native per-agent TTS (check releases before implementing)
- [ ] Write small Node.js proxy (`tts-router.js`) — runs in container background
- [ ] Proxy queries OpenClaw RPC for active agent before forwarding TTS request
- [ ] Add agent→voiceId registry (config or env vars)
- [ ] Set `messages.tts.elevenlabs.baseUrl` to proxy URL in `openclaw.json`
- [ ] Set `modelOverrides.enabled: false` once proxy is live
- [ ] Remove `[[tts:voiceId=...]]` directives from SOUL.md files (Merlin, Nimue)
- [ ] Add proxy startup to `entrypoint.sh`
- [ ] Test: send voice message to Merlin → verify Merlin voice
- [ ] Test: send voice message to Nimue → verify Nimue voice
- [ ] Test: attempt prompt injection `[[tts:voiceId=xyz]]` → verify ignored
- [ ] Update OPENCLAW-RUNBOOK.md (hsb0)

## Acceptance Criteria

- [ ] Merlin always uses `EQIVtVkE7IWwwaRgwyPi` regardless of model output
- [ ] Nimue always uses `D9MdulIxfrCUUJcGNQon` regardless of model output
- [ ] `[[tts:voiceId=...]]` in model output is stripped/ignored
- [ ] Voice change requires only config update, not SOUL.md edit
- [ ] No regression on Groq STT or other TTS behavior

## Notes

- **Current stopgap**: `modelOverrides.enabled: true` + `[[tts:voiceId=...]]` in each agent's `SOUL.md`
- Voice IDs: Merlin = `EQIVtVkE7IWwwaRgwyPi`, Nimue = `D9MdulIxfrCUUJcGNQon`
- Architectural design doc: see session notes 2026-02-28 (SYSOP session)
- Consider filing OpenClaw feature request for native `agents.list[].messages.tts` — would make this proxy unnecessary
- hsb0 only for now; miniserver-bp (Percy/James) has no TTS yet
