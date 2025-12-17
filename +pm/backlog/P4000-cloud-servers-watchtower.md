# Add Watchtower to Cloud Servers (csb0, csb1)

## Priority: HIGH

## Description

Neither csb0 nor csb1 run Watchtower for automatic Docker container updates. This means containers on these servers must be manually updated.

## Current State

| Host | Watchtower | Container Updates            |
| ---- | ---------- | ---------------------------- |
| hsb1 | ✅ Running | Automatic (weekly + pidicon) |
| csb0 | ❌ Missing | Manual only                  |
| csb1 | ❌ Missing | Manual only                  |

## Why This Matters

- **Security**: Containers may run with known vulnerabilities
- **Maintenance burden**: Manual updates are easy to forget
- **Inconsistency**: hsb1 has auto-updates, cloud servers don't

## Implementation

Add Watchtower to docker-compose on both cloud servers:

```yaml
watchtower:
  image: containrrr/watchtower:latest
  container_name: watchtower
  restart: unless-stopped
  command: --schedule "0 0 4 * * *" --cleanup
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:rw
  environment:
    - "WATCHTOWER_CLEANUP=true"
    - "DOCKER_API_VERSION=1.44" # Required for modern Docker!
    - "WATCHTOWER_NOTIFICATIONS=shoutrrr"
  env_file:
    - /path/to/watchtower.env # Telegram notification URL
```

## Acceptance Criteria

- [ ] Watchtower running on csb0
- [ ] Watchtower running on csb1
- [ ] Both configured with `DOCKER_API_VERSION=1.44`
- [ ] Telegram notifications working
- [ ] Verify at least one update cycle completes successfully

## Notes

- Remember `DOCKER_API_VERSION=1.44` — without this, Watchtower fails on modern Docker (see hsb1 fix from 2025-12-14)
- Consider weekly schedule to avoid disruption during business hours
- May need to create watchtower.env with Telegram shoutrrr URL

## Related

- hsb1 Watchtower fix: `+pm/backlog/3-low/2025-12-14-hsb1-watchtower-docker-api-version.md`
