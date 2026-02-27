# James Agent — miniserver-bp

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-27

---

## Problem

Percy (Percaival) is Markus's personal work assistant on miniserver-bp. Dominik Korpič (Sales Operations & PM) needs his own agent — James — running on the same gateway. James handles internal ops, sales operations, and sales-to-PM handovers for Dominik.

## Solution

Add James as a second agent to the existing `openclaw-percaival` container via OpenClaw's native multi-agent config. Config-only change — no new container, no new Dockerfile.

## Identities

| What           | Value                                        |
| -------------- | -------------------------------------------- |
| Agent name     | James                                        |
| Serves         | Dominik Korpič                               |
| Dominik email  | dominik.korpic@bytepoets.com                 |
| Telegram bot   | New bot — register via @BotFather            |
| Mattermost     | New bot account on mattermost.bytepoets.com  |
| GitHub account | New: `bytepoets-jamesai` (or similar)        |
| Workspace repo | `bytepoets-mba/oc-workspace-james` (private) |

## Scope

- Internal BYTEPOETS operations
- Sales operations and pipeline management
- Sales → project management handover
- Dominik's calendar, email, Mattermost
- NOT: Markus's personal context, home automation, family

## Implementation

- [ ] Register Telegram bot via @BotFather → store token in `secrets/miniserver-bp-james-telegram-token.age`
- [ ] Create Mattermost bot account for James on mattermost.bytepoets.com
- [ ] Create GitHub account `bytepoets-jamesai` + PAT → `secrets/miniserver-bp-james-github-pat.age`
- [ ] Register both secrets in `secrets/secrets.nix`
- [ ] Declare secrets in `hosts/miniserver-bp/configuration.nix` (mode 444)
- [ ] Mount secrets in `docker-compose.yml` + export in entrypoint
- [ ] Add James to `agents.list[]` in `openclaw.json` with workspace + agentDir paths
- [ ] Add `channels.telegram.accounts.james` + `channels.mattermost.accounts.james` in `openclaw.json`
- [ ] Add James to `bindings[]` for both channels
- [ ] Enable `tools.agentToAgent` for `["main", "james"]` + `sessions.visibility: "all"`
- [ ] Create `bytepoets-mba/oc-workspace-james` repo with full workspace files (SOUL, USER, TOOLS, IDENTITY, MEMORY, AGENTS, HEARTBEAT)
- [ ] Wire workspace clone in entrypoint (same pattern as Percy)
- [ ] Deploy: `gitpl && just switch && just oc-restart msbp`
- [ ] Pair Dominik on Telegram: `openclaw pairing approve telegram <CODE> --account james`
- [ ] Pair Dominik on Mattermost
- [ ] Run `just oc-memory-index msbp` after first boot
- [ ] Documentation update (OPENCLAW-RUNBOOK.md)

## Acceptance Criteria

- [ ] James responds in Telegram (Dominik's Telegram)
- [ ] James responds in Mattermost
- [ ] Percy and James can communicate via `sessions_send`
- [ ] James workspace git-managed, memory indexed
- [ ] Dominik paired on both channels
- [ ] Percy unaffected

## Notes

- No new container — OpenClaw multi-agent handles routing natively
- `agentId: "james"` — Percy keeps `"main"` for backward compat
- Workspace files: English instruction files, German memory files
- British butler tone — dignified, professional, sales/ops focused
- Emoji skin tone: always 🏻 light — never yellow
- Agent-to-agent: Percy + James can coordinate (same gateway)
- Mattermost: James needs own bot account (not Percy's) — create in Mattermost admin

## Prep Work Done (2026-02-27)

- ✅ `tools.agentToAgent.enabled: true` + `tools.sessions.visibility: "all"` added to `openclaw.json`
- ✅ Committed + pushed to nixcfg (commit `4fe74a54`)
- ⏳ `just oc-restart msbp` still needed to activate (not yet live)
- ⏳ When James added: expand `tools.agentToAgent.allow` from `["main"]` to `["main", "james"]`
- ⏳ Three things needed from Markus before implementation starts:
  1. Telegram bot token — register @james bot via @BotFather
  2. Mattermost bot account for James on mattermost.bytepoets.com
  3. GitHub account `bytepoets-jamesai` + PAT
- Hardware check done: 3.2GB RAM free on miniserver-bp — no issue running 2 agents
