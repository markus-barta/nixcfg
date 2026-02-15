# Harmonize OpenClaw Deployments (Merlin + Percy)

**Host**: miniserver-bp (primary), hsb0 (secondary changes)
**Priority**: P40
**Status**: Backlog
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

- [ ] Create `hosts/miniserver-bp/docker/docker-compose.yml`
- [ ] Remove `virtualisation.oci-containers.containers.openclaw-percaival` from `configuration.nix`
- [ ] Keep activation script for dir creation + `openclaw.json` seeding
- [ ] Keep agenix secrets, mount via compose volumes
- [ ] Verify: `docker compose up -d` starts Percy on port 18789

## 2. No plaintext secrets

OpenClaw supports `${ENV_VAR}` substitution in `openclaw.json` (see docs.openclaw.ai/gateway/configuration).

- [ ] Merlin: add `TELEGRAM_BOT_TOKEN` and `OPENCLAW_GATEWAY_TOKEN` to entrypoint (read from agenix mounts)
- [ ] Percy: same pattern — entrypoint reads secrets into env vars
- [ ] Both: update `openclaw.json` seed to use `${TELEGRAM_BOT_TOKEN}` and `${OPENCLAW_GATEWAY_TOKEN}`
- [ ] Both: remove hardcoded tokens from live `openclaw.json` on hosts
- [ ] Percy: move Brave API key from `openclaw.json` `tools.web.search.apiKey` to env var

## 3. Harmonize Dockerfiles

Both get all tools installed; host-specific ones just aren't used unless configured.

```
Shared (both):        git, curl, jq, openclaw@latest, sharp, @pnp/cli-microsoft365
Merlin-specific:      vdirsyncer, khal, mosquitto-clients
Percy-specific:       gogcli (pinned binary)
```

- [ ] Add `jq` to Percy's Dockerfile
- [ ] Add gogcli install block to Merlin's Dockerfile (commented out or active)
- [ ] Add vdirsyncer/khal/mosquitto-clients to Percy's Dockerfile (commented out or active)
- [ ] Decide: install everything on both (simpler updates) vs keep host-specific (smaller images)
- [ ] Create config dirs for all tools in both Dockerfiles

## 4. Shared skills (available, not necessarily active)

Custom skills live in `/var/lib/openclaw-*/data/workspace/skills/`. They activate based on tool availability and config.

### Current inventory

| Skill                               | Merlin | Percy  | Host-specific?               |
| ----------------------------------- | ------ | ------ | ---------------------------- |
| `calendar` (caldav/vdirsyncer/khal) | Active | --     | Yes (Merlin's iCloud creds)  |
| `home-assistant`                    | Active | --     | Yes (home LAN only)          |
| `opus-gateway` (EnOcean)            | Active | --     | Yes (home LAN only)          |
| `openrouter-free-models`            | Active | --     | No — useful for both         |
| `m365-email`                        | --     | Active | Partially (Percy's identity) |

### Tasks

- [ ] Copy `openrouter-free-models` skill to Percy
- [ ] Copy `m365-email` skill to Merlin (adapt identity when Merlin gets Azure AD app)
- [ ] Copy `calendar`, `home-assistant`, `opus-gateway` skill SKILL.md files to Percy (won't activate — tools/endpoints not available, but ready if needed)
- [ ] Version-control skill SKILL.md files in the repo (e.g., `hosts/<host>/docker/skills/`)
- [ ] Backup existing workspace skills before any changes

## 5. Harmonized entrypoint

Merlin's pattern is better — shell entrypoint reads secrets from mounted files into env vars, then execs gateway.

- [ ] Create shared entrypoint template
- [ ] Percy: adopt same pattern (currently uses Dockerfile CMD directly)
- [ ] Both: entrypoint reads `OPENROUTER_API_KEY`, `BRAVE_API_KEY`, `TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN` from mounted secret files

## 6. Harmonized RUNBOOK docs

- [ ] Same OPENCLAW-RUNBOOK.md structure in both `hosts/<host>/docs/`
- [ ] Sections: overview, start/stop, update, re-auth, skills, troubleshooting
- [ ] Host-specific content (connection details, skill details) stays per host

---

## Acceptance Criteria

- [ ] Percy starts via `docker compose up -d` (no oci-containers)
- [ ] No `virtualisation.oci-containers` for openclaw in msbp `configuration.nix`
- [ ] Zero plaintext secrets in `openclaw.json` on both hosts
- [ ] All 5 custom skills present on both hosts (active per config)
- [ ] Both Dockerfiles follow same structure
- [ ] Both use entrypoint secret-reading pattern
- [ ] OPENCLAW-RUNBOOK.md exists and is current for both hosts
- [ ] Telegram bot responds on both hosts after migration
- [ ] M365 + gogcli integrations work on Percy
- [ ] Home Assistant + Opus Gateway work on Merlin

## Notes

- Do Percy migration first (higher risk — changing management approach)
- Test Merlin changes second (lower risk — already on docker-compose)
- Depends on: P50--09e96a9 (update automation) for ongoing maintenance
- Skills are runtime data — back up before touching workspace dirs
