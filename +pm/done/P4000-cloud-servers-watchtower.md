# Add Watchtower to Cloud Servers (csb0, csb1)

**Priority**: P4 (Medium)  
**Completed**: 2025-12-21  
**Status**: DONE (Archived - Use beatkind/watchtower)

> ⚠️ **MIGRATED**: As of 2025-12-27, containrrr/watchtower is archived. See [P7xxx](#) for migration to beatkind/watchtower.

## Description

Add automatic Docker container updates to cloud servers using Watchtower with built-in shoutrrr for Telegram notifications.

## Current State

| Host | Watchtower | Schedule  | Notifications |
| ---- | ---------- | --------- | ------------- |
| hsb1 | ✅ Running | Sat 05:00 | Telegram      |
| csb0 | ❌ Missing | -         | -             |
| csb1 | ❌ Missing | -         | -             |

## Implementation

Add to `~/docker/docker-compose.yml` on **both** csb0 and csb1:

```yaml
watchtower:
  image: containrrr/watchtower:latest
  container_name: watchtower
  restart: unless-stopped
  command: --schedule "0 0 8 * * SAT" --cleanup
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:rw
  environment:
    - WATCHTOWER_CLEANUP=true
    - DOCKER_API_VERSION=1.44
    - WATCHTOWER_NOTIFICATIONS=shoutrrr
    - WATCHTOWER_NOTIFICATIONS_HOSTNAME=csb0 # ← Shows "Watchtower updates on csb0"
    - WATCHTOWER_NOTIFICATION_TITLE_TAG=[CLOUD] # ← Optional prefix
  env_file:
    - ./watchtower.env
```

Create `~/docker/watchtower.env`:

```bash
WATCHTOWER_NOTIFICATION_URL=telegram://BOT_TOKEN@telegram?chats=CHAT_ID
```

### Notification Config Explained

| Variable                            | Purpose              | Example Output                      |
| ----------------------------------- | -------------------- | ----------------------------------- |
| `WATCHTOWER_NOTIFICATIONS_HOSTNAME` | Server name in title | "updates on **csb0**"               |
| `WATCHTOWER_NOTIFICATION_TITLE_TAG` | Prefix (optional)    | "**[CLOUD]** Watchtower updates..." |

Result: `[CLOUD] Watchtower updates on csb0`

**Docs**: <https://containrrr.dev/watchtower/notifications/>

## Steps

1. SSH to csb0: `ssh mba@cs0.barta.cm -p 2222`
2. Add watchtower service to `~/docker/docker-compose.yml`
3. Create `~/docker/watchtower.env` with Telegram credentials
4. `docker-compose up -d watchtower`
5. Verify: `docker logs watchtower`
6. Repeat for csb1

## Acceptance Criteria

- [x] Watchtower running on csb0
- [x] Watchtower running on csb1
- [x] Schedule: Saturday 08:00 (`0 0 8 * * SAT`)
- [x] `DOCKER_API_VERSION=1.44` set (required!)
- [x] Telegram notifications configured with hostname
- [x] **Bonus**: Fixed hsb1 hostname (was showing hash)

## Notes

- **Critical**: `DOCKER_API_VERSION=1.44` required for modern Docker (learned from hsb1)
- Uses shoutrrr (built-in) — no Apprise dependency
- Same bot token as building automation (`JHW22_BOT_TOKEN`)
- **Also update hsb1**: Add `WATCHTOWER_NOTIFICATIONS_HOSTNAME=hsb1` to fix the cryptic hash there too

## Related

- hsb1 Watchtower fix: `+pm/done/P6000-hsb1-watchtower-docker-api-version.md`
