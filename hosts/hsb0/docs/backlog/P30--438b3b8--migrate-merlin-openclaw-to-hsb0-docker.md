# Migrate Merlin (OpenClaw) from hsb1 Nix package to hsb0 Docker

**Host**: hsb0
**Priority**: P30
**Status**: Backlog
**Created**: 2026-02-13

---

## Problem

Merlin (OpenClaw AI assistant) runs on hsb1 as a **Nix package built from source**. This is:

- **Brittle**: `pnpm` monorepo build with native deps (`node-llama-cpp`, `cmake`, `python3`), platform-specific hashes, version patching hacks
- **High maintenance**: Every OpenClaw update requires rebuilding the Nix package, updating hashes, fixing build breakage
- **Fragile state**: Imperative config (`openclaw.json`, auth profiles, cron jobs, skill symlinks) -- skill symlinks break on Nix GC/updates
- **Known broken**: iCal sync (P40 backlog), skill symlinks pointing to GC'd store paths

Percy (miniserver-bp) runs OpenClaw in **Docker** via `npm install -g openclaw@latest` and is far more stable and easier to update. Merlin should follow the same pattern but on hsb0.

## Solution

Migrate Merlin to a **Docker container on hsb0**, replicating the proven miniserver-bp pattern (`virtualisation.oci-containers`). Transfer persistent state (config, workspace, skills, cron jobs) from hsb1. Stop (but don't delete) the hsb1 service so it doesn't interfere.

### Why hsb0?

- hsb1 (Mac mini 2014, 16GB) stays available for other workloads
- hsb0 (Mac mini 2011, 8GB, 223GB free SSD) has Docker already running, modest but sufficient for OpenClaw
- hsb0 is the DNS/DHCP crown jewel but OpenClaw is low-risk (container-isolated, `--network=host`)
- Home LAN, same network as hsb1 -- Home Assistant still reachable at `192.168.1.101:8123`

### Architecture comparison

| Aspect   | hsb1 (current)                      | hsb0 (target)                                     |
| -------- | ----------------------------------- | ------------------------------------------------- |
| Runtime  | Nix package (pnpm from-source)      | Docker container (npm registry)                   |
| Service  | `systemd.services.openclaw-gateway` | `virtualisation.oci-containers`                   |
| Config   | Imperative (`~/.openclaw/`)         | Activation script seeds `openclaw.json`           |
| Secrets  | env vars via wrapper script         | agenix → mounted files + activation script        |
| Update   | Rebuild Nix package (hard)          | `docker build --no-cache` (easy)                  |
| Skills   | Imperative + broken symlinks        | Workspace volume (persistent)                     |
| Calendar | vdirsyncer + khal (native)          | vdirsyncer + khal inside container (or Graph API) |

## Current Merlin State (hsb1)

### Secrets (6 total)

| Secret                          | Purpose                   | Migration                                                      |
| ------------------------------- | ------------------------- | -------------------------------------------------------------- |
| `hsb1-openclaw-gateway-token`   | Gateway WS auth           | Create new `hsb0-openclaw-*` secrets                           |
| `hsb1-openclaw-telegram-token`  | `@merlin_oc_bot` Telegram | **Reuse** -- same bot, new host                                |
| `hsb1-openclaw-openrouter-key`  | LLM inference             | **Reuse** -- same API key                                      |
| `hsb1-openclaw-hass-token`      | Home Assistant            | **Reuse** -- HASS at `192.168.1.101` still reachable from hsb0 |
| `hsb1-openclaw-brave-key`       | Web search                | **Reuse** -- same API key                                      |
| `hsb1-openclaw-icloud-password` | CalDAV sync               | Evaluate: replace with M365 calendar or keep iCloud            |

### Persistent state to transfer

| What              | hsb1 path                     | Transfer method                               |
| ----------------- | ----------------------------- | --------------------------------------------- |
| `openclaw.json`   | `~/.openclaw/openclaw.json`   | Copy, adapt for Docker paths                  |
| Agent config      | `~/.openclaw/agents/main/`    | Copy (auth profiles, memory, sessions)        |
| Workspace         | `~/.openclaw/workspace/`      | Copy (skills, files, knowledge)               |
| Cron jobs         | `~/.openclaw/cron/jobs.json`  | Copy                                          |
| vdirsyncer config | `~/.config/vdirsyncer/config` | Evaluate: install in container or drop iCloud |
| khal config       | `~/.config/khal/config`       | Same as above                                 |

### Services/skills

| Service                     | How connected                                    | hsb0 impact                                                           |
| --------------------------- | ------------------------------------------------ | --------------------------------------------------------------------- |
| Telegram (`@merlin_oc_bot`) | Bot token env var                                | Same token, only one instance can poll -- **must stop hsb1 first**    |
| OpenRouter (LLM)            | API key env var                                  | No change                                                             |
| Brave Search                | API key env var                                  | No change                                                             |
| Home Assistant              | HASS token, skill reads from `/run/agenix/` path | Mount secret in container, update skill config for new path           |
| iCloud Calendar             | vdirsyncer + khal                                | **Decision needed**: install in container, use M365 calendar, or drop |
| Cron/scheduler              | Built-in OpenClaw                                | Transfer `jobs.json`                                                  |

## Implementation

### Phase 0: Preparation

- [ ] Decide on calendar approach: keep iCloud (vdirsyncer in container), switch to M365, or drop
- [ ] Document current Merlin `openclaw.json` settings (model, temperature, skills config, bindings)
- [ ] Verify hsb0 resources: `free -h`, `df -h`, `docker ps` (confirm capacity)

### Phase 1: Dockerfile + NixOS config on hsb0

- [ ] Create `hosts/hsb0/docker/openclaw-merlin/Dockerfile` (based on miniserver-bp pattern)
  - `node:22-bookworm-slim`
  - `openclaw@latest`
  - `gogcli` if Google Workspace needed (Merlin doesn't use it currently)
  - `vdirsyncer` + `khal` if keeping iCloud calendar
  - Any other Merlin-specific binaries
- [ ] Add `virtualisation.oci-containers` definition to `hosts/hsb0/configuration.nix`
  - Container: `openclaw-merlin`
  - `--network=host`
  - Port: `18789`
  - Volume: `/var/lib/openclaw-merlin/data:/home/node/.openclaw:rw`
  - agenix secrets mounted read-only
- [ ] Create agenix secrets for hsb0:
  - `hsb0-openclaw-gateway-token.age` (new token)
  - `hsb0-openclaw-telegram-token.age` (copy from hsb1)
  - `hsb0-openclaw-openrouter-key.age` (copy from hsb1)
  - `hsb0-openclaw-hass-token.age` (copy from hsb1)
  - `hsb0-openclaw-brave-key.age` (copy from hsb1)
  - `hsb0-openclaw-icloud-password.age` (if keeping iCloud)
- [ ] Add secrets to `secrets/secrets.nix` with hsb0 host key
- [ ] Add activation script to seed `openclaw.json` with Telegram token
- [ ] Open port 18789 in hsb0 firewall

### Phase 2: Transfer state from hsb1

- [ ] Stop Merlin on hsb1: `sudo systemctl stop openclaw-gateway`
- [ ] Copy persistent state from hsb1 to hsb0:
  ```bash
  # From hsb0:
  sudo mkdir -p /var/lib/openclaw-merlin/data
  scp -r mba@hsb1.lan:~/.openclaw/{openclaw.json,agents,workspace,cron} /tmp/merlin-state/
  # Adapt openclaw.json paths for Docker (e.g., /home/node/.openclaw/)
  sudo cp -r /tmp/merlin-state/* /var/lib/openclaw-merlin/data/
  sudo chown -R 1000:1000 /var/lib/openclaw-merlin/data
  ```
- [ ] Adapt `openclaw.json`:
  - Gateway bind: `lan` (for LAN access)
  - `allowInsecureAuth: true` (HTTP control UI)
  - Update HASS token path if needed
  - Verify Telegram bot token injection
- [ ] If keeping iCloud: copy vdirsyncer + khal configs into container volume

### Phase 3: Build + Deploy on hsb0

- [ ] Commit + push
- [ ] Pull on hsb0: `cd ~/Code/nixcfg && git pull`
- [ ] Build Docker image: `cd hosts/hsb0/docker/openclaw-merlin && docker build -t openclaw-merlin:latest .`
- [ ] NixOS rebuild: `sudo nixos-rebuild switch --flake .#hsb0`
- [ ] **Important**: Mask service first for onboard wizard if fresh config:
  ```bash
  sudo systemctl mask docker-openclaw-merlin
  # Run onboard if needed, then unmask
  sudo systemctl unmask docker-openclaw-merlin
  sudo systemctl start docker-openclaw-merlin
  ```

### Phase 4: Verify + Test

- [ ] Verify gateway starts: `docker logs openclaw-merlin`
- [ ] Check status: `curl http://192.168.1.99:18789/health`
- [ ] Test Telegram: send message to `@merlin_oc_bot` -- should respond from hsb0 now
- [ ] Test Home Assistant: ask Merlin to check lights/sensors
- [ ] Test Brave Search: ask Merlin to search the web
- [ ] Test cron: verify scheduled tasks run
- [ ] Test calendar (if applicable)
- [ ] Verify memory/context carried over from hsb1

### Phase 5: Decommission hsb1 OpenClaw

- [ ] Disable (don't delete) hsb1 service:
  ```nix
  # In hsb1/configuration.nix:
  systemd.services.openclaw-gateway.enable = false;
  ```
  Or simpler: mask the service
- [ ] Keep hsb1 secrets in repo (don't delete -- rollback safety)
- [ ] Keep hsb1 `openclaw` package in config but remove from `wantedBy` (so it's available but not running)
- [ ] **Do NOT delete** hsb1 state (`~/.openclaw/`) -- keep as backup for 30 days minimum
- [ ] Remove `vdirsyncer` and `khal` from hsb1 packages if no longer needed

### Phase 6: Cleanup + Docs

- [ ] Update hsb0 README.md (add OpenClaw/Merlin to services)
- [ ] Update hsb0 RUNBOOK.md (add OpenClaw operational commands)
- [ ] Create `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md` (based on miniserver-bp template)
- [ ] Update hsb1 README.md (note Merlin migrated to hsb0)
- [ ] Update hsb1 RUNBOOK.md (note service disabled, state preserved)
- [ ] Update `docs/INFRASTRUCTURE.md` (Merlin now on hsb0)
- [ ] Consider: close/update related backlog items:
  - `P94--0e9a020--openclaw-deployment.md` (hsb1) -- superseded
  - `P66--56fe6e8--declarative-openclaw-skills.md` (hsb1) -- Docker makes this moot
  - `P40--0c5e66c--ical-sync-fix.md` (hsb1) -- migrated or replaced
  - `P66--5c3930e--declarative-openclaw-gateway.md` (infra) -- Docker approach instead
  - `P40--0dd6291--openclaw-update-automation.md` (infra) -- Docker `--no-cache` rebuild is trivial

## Acceptance Criteria

- [ ] Merlin responds via Telegram (`@merlin_oc_bot`) from hsb0
- [ ] Home Assistant integration works (lights, sensors)
- [ ] Brave Search works
- [ ] Cron/scheduled tasks execute
- [ ] Calendar works (if applicable)
- [ ] Memory/context preserved from hsb1
- [ ] hsb1 OpenClaw service stopped and disabled (not deleted)
- [ ] hsb1 state preserved as backup
- [ ] All docs updated (hsb0 README/RUNBOOK, hsb1 README/RUNBOOK, INFRASTRUCTURE.md)
- [ ] `docker build --no-cache` successfully updates OpenClaw (test upgrade path)

## Risks

| Risk                                       | Impact                           | Mitigation                                                                   |
| ------------------------------------------ | -------------------------------- | ---------------------------------------------------------------------------- |
| hsb0 resource constraint (8GB RAM, 2C CPU) | Merlin slow or OOM               | Monitor with `docker stats`; OpenClaw is mostly API calls, low local compute |
| Telegram bot token conflict                | Two instances polling = errors   | **Stop hsb1 BEFORE starting hsb0** -- only one instance per bot token        |
| HASS token path change                     | Home Assistant skill breaks      | Mount secret at known path in container                                      |
| State transfer incomplete                  | Lost memory/context              | Verify file list before decommissioning hsb1; keep hsb1 backup 30 days       |
| iCloud CalDAV in container                 | Complex setup                    | Consider dropping iCloud, use M365 calendar or Google Calendar instead       |
| hsb0 is crown jewel (DNS/DHCP)             | Container issue could affect DNS | OpenClaw is isolated in container; `--network=host` risk is low              |

## Key Gotchas (from miniserver-bp experience)

1. **`--network=host` is REQUIRED** -- Docker bridge causes "pairing required" errors
2. **`bind=lan`** in `openclaw.json` -- keeps Control UI accessible from LAN
3. **Run as `node` user** (uid 1000) -- otherwise `$HOME` mismatch breaks volume mounts
4. **`git` required** in Docker image for npm install
5. **Onboard wizard must run BEFORE gateway starts** -- gateway spins at 99% CPU without config
6. **Mask systemd service** during initial setup / onboard wizard
7. **`allowInsecureAuth: true`** needed for HTTP Control UI access (no HTTPS on LAN)
8. **Nix package approach is NOT recommended** -- Docker is more practical (lesson learned from hsb1)

## References

- miniserver-bp Docker setup (template): `hosts/miniserver-bp/docs/OPENCLAW-DOCKER-SETUP.md`
- miniserver-bp runbook (template): `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md`
- hsb1 current config: `hosts/hsb1/configuration.nix` (lines 506-611)
- hsb1 runbook: `hosts/hsb1/docs/RUNBOOK.md` (lines 543-646)
- Nix package (to be deprecated): `pkgs/openclaw/package.nix`
- OpenClaw docs: https://docs.openclaw.ai
- Related backlog: P66--5c3930e (declarative gateway), P45--3f8672e (HA skill), P48--025353e (cache)
