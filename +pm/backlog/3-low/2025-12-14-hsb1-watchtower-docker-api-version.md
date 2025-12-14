# hsb1 Watchtower Docker API Version Fix

## Description

Sync the `DOCKER_API_VERSION=1.44` fix applied to `~/docker/docker-compose.yml` on hsb1 to the source repository (if managed elsewhere).

## Background

On 2025-12-14, Watchtower was found to be completely non-functional due to Docker API version mismatch:

```
Error response from daemon: client version 1.25 is too old. Minimum supported API version is 1.44
```

Watchtower defaults to Docker API 1.25 regardless of image version, but hsb1's Docker daemon (v29.1.2) requires minimum API 1.44.

## Fix Applied

Added `DOCKER_API_VERSION=1.44` to both Watchtower services in `~/docker/docker-compose.yml`:

```yaml
watchtower-weekly:
  environment:
    - "WATCHTOWER_CLEANUP=true"
    - "DOCKER_API_VERSION=1.44" # <-- Added
    # ...

watchtower-pidicon:
  environment:
    - "WATCHTOWER_CLEANUP=true"
    - "DOCKER_API_VERSION=1.44" # <-- Added
    # ...
```

## Current State

- ✅ Fix applied directly on hsb1 (`~/docker/docker-compose.yml`)
- ⚠️ Source repository may not have this change (if docker-compose.yml is managed in git)

## Acceptance Criteria

- [ ] Determine if `~/docker/docker-compose.yml` is managed in a git repository
- [ ] If yes, commit the `DOCKER_API_VERSION=1.44` change to that repo
- [ ] If no, document this as a manual hsb1 configuration

## Priority

Low — fix is already applied and working on hsb1. This is about documentation/sync.

## Related

- Watchtower services: `watchtower-weekly`, `watchtower-pidicon`
- Docker version on hsb1: 29.1.2 (API 1.52, min 1.44)
