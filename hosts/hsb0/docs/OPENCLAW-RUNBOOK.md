# OpenClaw Runbook - hsb0

**Host**: hsb0 (192.168.1.99)
**Instance**: Merlin
**Port**: 18789
**Version**: latest (npm, Docker)
**Updated**: 2026-02-14

---

## Current Status

| Component       | Status        | Notes                            |
| --------------- | ------------- | -------------------------------- |
| Container       | ✅ Running    | Docker, `--network=host`         |
| Telegram        | ✅ Connected  | @merlin_oc_bot                   |
| Home Assistant  | ✅ Working    | HASS at 192.168.1.101:8123       |
| Brave Search    | ✅ Working    | Web search skill                 |
| Cron            | ✅ Working    | Built-in scheduler               |
| iCloud Calendar | ❌ Broken     | P40 -- vdirsyncer sync needs fix |
| M365 Calendar   | ❌ Not setup  | Azure AD app not yet created     |
| Opus Gateway    | ✅ Configured | Credentials mounted from agenix  |

## Operational Commands

### Check Status

```bash
# Container status
sudo systemctl status docker-openclaw-merlin
docker ps | grep openclaw

# View logs
docker logs -f openclaw-merlin

# Gateway health
curl http://192.168.1.99:18789/health
```

### Restart

```bash
sudo systemctl restart docker-openclaw-merlin

# Or via docker compose:
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose restart openclaw-merlin
```

### Force Recreate (fresh boot)

```bash
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose up -d --force-recreate openclaw-merlin

# With rebuild:
docker compose build --no-cache openclaw-merlin
docker compose up -d --force-recreate openclaw-merlin
```

### Stop (Prevent Auto-Restart)

```bash
sudo systemctl mask docker-openclaw-merlin
sudo systemctl stop docker-openclaw-merlin
# Later: sudo systemctl unmask docker-openclaw-merlin
```

### View Config

```bash
# Current config
cat /var/lib/openclaw-merlin/data/openclaw.json | jq

# Gateway token
docker exec openclaw-merlin openclaw dashboard --no-open
```

### Edit Config

```bash
sudo vim /var/lib/openclaw-merlin/data/openclaw.json
sudo systemctl restart docker-openclaw-merlin
```

### Update OpenClaw

```bash
cd ~/Code/nixcfg/hosts/hsb0/docker
docker compose build --no-cache openclaw-merlin
docker compose up -d openclaw-merlin
```

## Telegram Operations

### Pairing

```bash
# List pending pairings
docker exec -it openclaw-merlin openclaw pairing list telegram

# Approve pairing
docker exec -it openclaw-merlin openclaw pairing approve telegram <CODE>
```

### Check Channel Status

```bash
docker exec openclaw-merlin openclaw channels list
```

## Home Assistant

Token mounted at `/run/secrets/hass-token` inside the container (from `/run/agenix/hsb0-openclaw-hass-token` on host).

```bash
# Test HA connectivity from inside container
docker exec openclaw-merlin sh -c \
  'curl -s -H "Authorization: Bearer $(cat /run/secrets/hass-token)" \
   http://192.168.1.101:8123/api/states | jq length'
```

## Opus Gateway

Credentials for the home's Opus gateway are mounted from agenix:

- Host: `/run/agenix/hsb0-openclaw-opus-gateway`
- Container: `/home/node/.openclaw/credentials/opus-gateway.env`
- Format: `.env` file (KEY=VALUE lines)

## Secrets (Agenix)

| Secret                          | Purpose                              | Container path                                      |
| ------------------------------- | ------------------------------------ | --------------------------------------------------- |
| `hsb0-openclaw-gateway-token`   | Gateway WS auth                      | Seeded into `openclaw.json` at activation           |
| `hsb0-openclaw-telegram-token`  | Telegram bot                         | Seeded into `openclaw.json` at activation           |
| `hsb0-openclaw-openrouter-key`  | LLM inference (OpenRouter)           | `/run/secrets/openrouter-key`                       |
| `hsb0-openclaw-hass-token`      | Home Assistant LLAT                  | `/run/secrets/hass-token`                           |
| `hsb0-openclaw-brave-key`       | Brave Search API                     | `/run/secrets/brave-key`                            |
| `hsb0-openclaw-icloud-password` | iCloud CalDAV (personal calendar)    | Not yet mounted (P40 pending)                       |
| `hsb0-openclaw-opus-gateway`    | Opus home gateway credentials        | `/home/node/.openclaw/credentials/opus-gateway.env` |
| `hsb0-openclaw-m365-cal-*`      | Microsoft Graph (read-only calendar) | Not yet created (Azure AD app pending)              |

All secrets are `mode = "444"` in NixOS config for Docker read access.

## Files Reference

| What                    | Location                                               |
| ----------------------- | ------------------------------------------------------ |
| Dockerfile              | `hosts/hsb0/docker/openclaw-merlin/Dockerfile`         |
| docker-compose          | `hosts/hsb0/docker/docker-compose.yml`                 |
| NixOS config            | `hosts/hsb0/configuration.nix`                         |
| Config (host)           | `/var/lib/openclaw-merlin/data/openclaw.json`          |
| Workspace               | `/var/lib/openclaw-merlin/data/workspace/`             |
| Credentials             | `/var/lib/openclaw-merlin/data/credentials/`           |
| vdirsyncer config       | `/var/lib/openclaw-merlin/vdirsyncer/config`           |
| khal config             | `/var/lib/openclaw-merlin/khal/config`                 |
| Device identity         | `/var/lib/openclaw-merlin/data/identity/device.json`   |
| Paired devices          | `/var/lib/openclaw-merlin/data/devices/paired.json`    |
| Container logs          | `docker logs openclaw-merlin`                          |
| Gateway log             | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (in container) |
| Secrets (agenix, NixOS) | `secrets/hsb0-openclaw-*.age`                          |

## Access

| Service    | URL                        |
| ---------- | -------------------------- |
| Control UI | http://192.168.1.99:18789/ |
| Telegram   | @merlin_oc_bot             |

---

## Troubleshooting

### "pairing required" -- cron/tools fail after fresh deploy or container rebuild

**Symptom**:

```
[tools] cron failed: gateway closed (1008): pairing required
Gateway target: ws://192.168.1.99:18789
```

**Root cause**: The gateway's internal agent client needs to be registered as a paired device. On a fresh deploy or if `devices/paired.json` is empty/missing, the agent shows up in `devices/pending.json` but is never auto-approved. The CLI can't approve it either (chicken-and-egg: CLI itself needs gateway access).

**Diagnosis**:

```bash
# Check paired devices (should NOT be empty)
docker exec openclaw-merlin cat /home/node/.openclaw/devices/paired.json

# Check pending devices (if agent is stuck here, that's the problem)
docker exec openclaw-merlin cat /home/node/.openclaw/devices/pending.json
```

**Fix**: Copy the pending device entry into `paired.json` manually. Get the `deviceId` and `publicKey` from `pending.json`, then write:

```bash
# 1. Read the pending device
docker exec openclaw-merlin cat /home/node/.openclaw/devices/pending.json | jq

# 2. Extract deviceId and publicKey, then write paired.json
# (replace DEVICE_ID and PUBLIC_KEY with actual values from step 1)
docker exec openclaw-merlin sh -c 'echo "{\"DEVICE_ID\":{\"deviceId\":\"DEVICE_ID\",\"publicKey\":\"PUBLIC_KEY\",\"displayName\":\"agent\",\"platform\":\"linux\",\"clientId\":\"gateway-client\",\"clientMode\":\"backend\",\"role\":\"operator\",\"roles\":[\"operator\"],\"scopes\":[\"operator.admin\",\"operator.approvals\",\"operator.pairing\"],\"approvedAt\":$(date +%s)000}}" > /home/node/.openclaw/devices/paired.json'

# 3. Restart container
docker restart openclaw-merlin
```

**Prevention**: After migration or fresh deploy, always check that `paired.json` is not empty. The migration plan intentionally skips `devices/` (new identity per host), so this step is always needed on first boot.

**See also**: Percy hit the same issue with Docker bridge networking. On Percy, `--network=host` fixed the in-process agent path (cron, Telegram). Merlin already uses `--network=host` but still needed manual device pairing on first boot. See [Percy investigation log](../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md#investigation-log-docker-bridge-vs-loopback).

### "All models failed / Provider in cooldown"

**Symptom**: `FailoverError: 403 Key limit exceeded (monthly limit)` or `Provider openrouter is in cooldown`.

**Root cause**: OpenRouter monthly billing limit hit, or stale API key cached in `auth-profiles.json`.

**Diagnosis**:

```bash
# Check auth profiles for stale keys or cooldown state
docker exec openclaw-merlin cat /home/node/.openclaw/agents/main/agent/auth-profiles.json | jq

# Verify the agenix key works:
curl -s https://openrouter.ai/api/v1/auth/key \
  -H "Authorization: Bearer $(cat /run/agenix/hsb0-openclaw-openrouter-key)"
```

**Fix**:

```bash
# Edit auth-profiles.json inside container:
# 1. Remove "key" field from profiles (let env var take over)
# 2. Remove "disabledUntil" and "disabledReason" from usageStats
# 3. Reset "errorCount" to 0 and "failureCounts" to {}
docker exec -it openclaw-merlin vi /home/node/.openclaw/agents/main/agent/auth-profiles.json

# Then restart
docker restart openclaw-merlin
```

### "schedule.at is in the past"

**Symptom**: `cron.add` fails with `schedule.at is in the past: ... (N minutes ago)`.

**Cause**: A cron job was queued while the gateway was down (restart, pairing issue, etc.) and is now stale. Harmless -- the next scheduled occurrence will be created correctly. No action needed.

### CLI commands fail with "pairing required"

**Symptom**: `openclaw devices list`, `openclaw gateway status`, etc. fail even though cron and Telegram work fine.

**Cause**: This is a known quirk. CLI RPC commands use a separate WebSocket connection that enforces device pairing even on loopback. The in-process agent runtime (cron, Telegram, tools) is NOT affected -- it runs inside the gateway process.

**Workaround**: Use `openclaw doctor` (reads state directly, no RPC) or interact via Telegram. This is cosmetic and does not affect agent functionality.

---

## Migration History

Merlin migrated from hsb1 (Nix package, `systemd.services.openclaw-gateway`) to hsb0 (Docker) on 2026-02-13. Full cleanup of hsb1 infrastructure completed 2026-02-14.

- **Migration backlog**: `hosts/hsb0/docs/backlog/P30--438b3b8--migrate-merlin-openclaw-to-hsb0-docker.md`
- **hsb1 on-host state** (`~/.openclaw/`) kept as backup until 2026-03-14

## Related Documentation

- [hsb0 RUNBOOK](./RUNBOOK.md) - Main host runbook
- [Percy OPENCLAW-RUNBOOK](../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md) - Sister instance (miniserver-bp)
- [Migration Backlog (P30)](../backlog/P30--438b3b8--migrate-merlin-openclaw-to-hsb0-docker.md)
- [iCal Sync Fix (P40)](../backlog/P40--0c5e66c--ical-sync-fix.md)
