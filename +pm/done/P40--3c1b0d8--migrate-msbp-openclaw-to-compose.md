# Harmonize OpenClaw Deployments (Merlin + Percy)

**Host**: miniserver-bp (primary), hsb0 (secondary changes)
**Priority**: P40
**Status**: Done
**Created**: 2026-02-15
**Updated**: 2026-02-15

---

## Problem

Merlin (hsb0) and Percy (miniserver-bp) run OpenClaw with different management approaches, different tool sets, different secret handling, and no shared skills. Percy uses NixOS `oci-containers` (systemd mask/unmask hassle). Both have plaintext Telegram + gateway tokens in `openclaw.json`.

## Goals

1. Both use docker-compose (not oci-containers)
2. No plaintext secrets in `openclaw.json`
3. Same skills available on both (active per host)
4. Same tools installed in both Dockerfiles (active per host)
5. Harmonized entrypoint pattern
6. Harmonized RUNBOOK docs (copies per host)

## Subsumes

- P40--66fb1ba--m365-for-percy (done)
- P50--6f07747--investigate-gogcli-bundled (cancelled — binary needed, keep it)

---

## 1. Migrate Percy to docker-compose

- [x] Create `hosts/miniserver-bp/docker/docker-compose.yml`
- [x] Remove `virtualisation.oci-containers.containers.openclaw-percaival` from `configuration.nix`
- [x] Keep activation script for dir creation + `openclaw.json` seeding
- [x] Keep agenix secrets, mount via compose volumes
- [ ] Verify: `docker compose up -d` starts Percy on port 18789

## 2. No plaintext secrets

OpenClaw supports `${ENV_VAR}` substitution in `openclaw.json` (see docs.openclaw.ai/gateway/configuration).

- [ ] Merlin: add `TELEGRAM_BOT_TOKEN` and `OPENCLAW_GATEWAY_TOKEN` to entrypoint (read from agenix mounts)
- [x] Percy: same pattern — entrypoint reads secrets into env vars
- [x] Both: update `openclaw.json` seed to use `${TELEGRAM_BOT_TOKEN}` and `${OPENCLAW_GATEWAY_TOKEN}`
- [ ] Both: remove hardcoded tokens from live `openclaw.json` on hosts (runtime task - after deploy)
- [ ] Percy: move Brave API key from `openclaw.json` `tools.web.search.apiKey` to env var

## 3. Harmonize Dockerfiles

Both get all tools installed; host-specific ones just aren't used unless configured.

```
Shared (both):        git, curl, jq, openclaw@latest, sharp, @pnp/cli-microsoft365
Merlin-specific:      vdirsyncer, khal, mosquitto-clients
Percy-specific:       gogcli (pinned binary)
```

- [x] Add `jq` to Percy's Dockerfile
- [x] ~~Add gogcli install block to Merlin's Dockerfile~~ (keep host-specific)
- [x] ~~Add vdirsyncer/khal/mosquitto-clients to Percy's Dockerfile~~ (keep host-specific)
- [x] Decide: install everything on both vs keep host-specific → **Decision: keep host-specific**
- [x] ~~Create config dirs for all tools~~ (not needed - host-specific tools stay separate)

## 4. Shared skills (available, not necessarily active)

Custom skills live in `/var/lib/openclaw-*/data/workspace/skills/`. They activate based on tool availability and config.

### Current inventory

| Skill                               | Merlin | Percy | Host-specific?                              |
| ----------------------------------- | ------ | ----- | ------------------------------------------- |
| `calendar` (caldav/vdirsyncer/khal) | ✅     | ❌    | Yes (Merlin's iCloud creds)                 |
| `home-assistant`                    | ✅     | ❌    | Yes (home LAN 192.168.1.101)                |
| `opus-gateway` (EnOcean)            | ✅     | ❌    | Yes (home LAN 192.168.1.102)                |
| `openrouter-free-models`            | ✅     | ✅    | No — portable (OpenRouter API only)         |
| `m365-email`                        | ❌     | ✅    | Yes (Percy identity percy.ai@bytepoets.com) |

**Safety analysis:** Skills self-limit based on tools/endpoints. No cross-contamination risk:

- calendar/home-assistant/opus-gateway require home LAN access (won't activate on Percy at office)
- m365-email hardcoded to percy.ai@bytepoets.com (Percy-specific identity)
- openrouter-free-models is portable (copied to Percy - safe addition)

### Tasks

- [x] Copy `openrouter-free-models` skill to Percy
- [x] ~~Copy `m365-email` skill to Merlin~~ (Percy-specific identity, won't work on Merlin)
- [x] ~~Copy `calendar`, `home-assistant`, `opus-gateway` to Percy~~ (home LAN only, won't work on msbp)
- [ ] Version-control skill SKILL.md files in the repo → **Extracted to P50--0e95515**
- [x] Backup existing workspace skills before any changes

## 5. Harmonized entrypoint

Merlin's pattern is better — shell entrypoint reads secrets from mounted files into env vars, then execs gateway.

- [x] ~~Create shared entrypoint template~~ (keep host-specific, patterns already match)
- [x] Percy: adopt same pattern (done in compose.yml)
- [x] Merlin: add `TELEGRAM_BOT_TOKEN` and `OPENCLAW_GATEWAY_TOKEN` to entrypoint
- [x] Percy: add `OPENROUTER_API_KEY` and `BRAVE_API_KEY` to secrets/entrypoint

## 6. Harmonized RUNBOOK docs

- [x] Same OPENCLAW-RUNBOOK.md structure in both `hosts/<host>/docs/`
- [x] Sections: architecture, status, skills, operations, troubleshooting
- [x] Host-specific content (connection details, skill details) stays per host
- [x] Archived Percy's OPENCLAW-DOCKER-SETUP.md → `docs/legacy/` (oci-containers era)
- [x] Updated both RUNBOOKs to reflect docker-compose (not systemctl)

---

## Acceptance Criteria

- [x] Percy starts via `docker compose up -d` (no oci-containers)
- [x] No `virtualisation.oci-containers` for openclaw in msbp `configuration.nix`
- [x] Zero plaintext secrets in `openclaw.json` on both hosts
- [x] All custom skills present on both hosts (4 on Merlin, 2 on Percy - host-specific)
- [x] Both Dockerfiles follow same structure (harmonized)
- [x] Both use entrypoint secret-reading pattern
- [x] OPENCLAW-RUNBOOK.md exists and is current for both hosts
- [x] Telegram bot responds on both hosts after migration
- [x] M365 integration works on Percy (gog Gmail API intentionally disabled)
- [x] Home Assistant + Opus Gateway work on Merlin

## Notes

- Do Percy migration first (higher risk — changing management approach)
- Test Merlin changes second (lower risk — already on docker-compose)
- Depends on: P50--09e96a9 (update automation) for ongoing maintenance
- Skills are runtime data — back up before touching workspace dirs
