---
description: "OpenClaw bots ops context - load all agent runbooks + SYSOP role"
---

Read and follow @+agents/rules/AGENTS.md
Assume @+agents/rules/SYSOP.md role

## OpenClaw Infrastructure Overview

You are now operating in OpenClaw bot context. Two instances run across two hosts:

| Host          | Instance           | Agents                  | Port  | Telegram                      |
| ------------- | ------------------ | ----------------------- | ----- | ----------------------------- |
| hsb0          | openclaw-gateway   | Merlin + Nimue          | 18789 | @merlin_oc_bot, @nimue_oc_bot |
| miniserver-bp | openclaw-percaival | Percy (+ James planned) | 18789 | @percaival_bot                |

## Load All Runbooks

Read the following docs carefully before proceeding — they are the source of truth:

@hosts/hsb0/docs/OPENCLAW-RUNBOOK.md
@hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md

For host-level context (NixOS config, SSH, agenix, Docker):

@hosts/hsb0/docs/RUNBOOK.md
@hosts/miniserver-bp/docs/RUNBOOK.md

## Agents — Quick Reference

### Merlin (hsb0, home)

- Role: Personal assistant, home automation, calendar
- Identity: @merlin-ai-mba (GitHub), @merlin_oc_bot (Telegram)
- Workspace repo: `markus-barta/oc-workspace-merlin`
- Key skills: home-assistant, opus-gateway, calendar (CalDAV), openrouter-free-models
- SSH access to hsb1 as `merlin` user (wheel + docker)

### Nimue (hsb0, home)

- Role: Companion agent, multi-agent peer to Merlin
- Identity: @nimue-ai-mai (GitHub)
- Workspace repo: `markus-barta/oc-workspace-nimue`
- Key skills: bundled (gog, weather, skill-creator, healthcheck)
- Status: iCloud Calendar and Google not yet configured

### Percy / Percaival (miniserver-bp, work)

- Role: Work assistant, BYTEPOETS office context
- Identity: @bytepoets-percyai (GitHub), @percaival_bot (Telegram)
- Workspace repo: `bytepoets-mba/oc-workspace-percy`
- Key skills: gog (Google Workspace), m365-email (Exchange), openrouter-free-models, weather, healthcheck
- Google: percy.ai@bytepoets.com — Gmail, Calendar, Drive, Contacts, Sheets, Docs
- M365: percy.ai@bytepoets.com — restricted to @bytepoets.com internal only (Exchange transport rule)

### James (planned, miniserver-bp)

- Role: Future second agent on miniserver-bp multi-agent gateway
- Status: Not yet configured — backlog item `P40--6b8803b--percy-multi-agent-gateway-james.md`
- Activation: config-only change to `openclaw.json` + new bot token via agenix

## Current Deployment State

Check live status via SSH (read-only, no approval needed):

```bash
# hsb0 (Merlin + Nimue)
ssh mba@hsb0.lan "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep openclaw"

# miniserver-bp (Percy) — reachable via Tailscale (ssh msbp) or office LAN (ssh msbp-lan)
ssh msbp "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep openclaw"
```

## Last Known Version: 2026.2.26 — Breaking Changes Summary

Before any `just oc-rebuild` or `just percy-rebuild`, check the changelog:

| Breaking change                                                | Fix applied                                                            |
| -------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `channels.telegram` flat → `accounts.<id>` format              | ✅ Both hosts migrated                                                 |
| `controlUi.allowedOrigins` required for non-loopback           | ✅ Both hosts fixed                                                    |
| `controlUi.dangerouslyDisableDeviceAuth` required for HTTP     | ✅ Both hosts fixed                                                    |
| `--agent` flag removed from pairing commands → use `--account` | ✅ Docs updated                                                        |
| Telegram pairings lost after upgrade                           | Re-pair with `openclaw pairing approve telegram <CODE> --account <id>` |

**Doctor warning "Moved channels.telegram..."** — false positive, ignore. Config is already correct.

## Online Resources (check before any update/upgrade)

- **GitHub releases + changelog**: https://github.com/openclaw/openclaw/releases
  → Check this for latest version, breaking changes, and migration notes before any `just oc-rebuild` or `just percy-rebuild`
- **Official docs**: https://openclaw.ai/
- **Troubleshooting**: https://docs.openclaw.ai/help/troubleshooting
- **ClawHub skill registry**: https://clawhub.ai

## Key Operational Commands

### hsb0 (Merlin + Nimue)

```bash
just oc-rebuild             # update to latest openclaw + recreate container (~5-10 min)
just oc-status              # container status + recent logs
just oc-stop && just oc-start   # restart without rebuild
just merlin-pull-workspace  # git pull Merlin workspace inside container
just nimue-pull-workspace   # git pull Nimue workspace inside container
```

### miniserver-bp (Percy)

```bash
just percy-rebuild          # update + recreate container (~15 min — pip installs pymupdf4llm)
just percy-status           # container status + recent logs
just percy-stop && just percy-start   # restart without rebuild
just percy-pull-workspace   # git pull Percy workspace inside container
```

### Secret rotation (both hosts — same pattern)

```bash
# 1. Mac: encrypt new value
agenix -e secrets/<host>-<secret-name>.age

# 2. Commit + push
git add secrets/<host>-<secret-name>.age && git commit -m "secrets: rotate <secret>" && git push

# 3. On host (ALL THREE steps required — agenix decrypts on NixOS switch, not docker rebuild!):
gitpl && just switch && just oc-rebuild   # hsb0
gitpl && just switch && just percy-rebuild  # miniserver-bp
```

## SYSOP Rules Reminder

- All config changes → nixcfg repo only. Never direct edits on hosts.
- Secrets → agenix only. Never plaintext in configs.
- NixOS builds → never on macOS. Use `ssh mba@gpc0.lan` or build on target host.
- Long ops (rebuilds) → provide commands only; Markus runs them. State time estimate.
- HIL protocol → PROPOSE before any state change. Risk: hsb0 = Crown Jewel (DNS/DHCP).
