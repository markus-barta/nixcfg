# opus-mqtt-credentials

**Host**: hsb1
**Priority**: P63
**Status**: Backlog
**Created**: 2025-12-05
**Updated**: 2026-01-06

---

## Problem

`opus-stream-to-mqtt` Docker container uses plain-text `.env` file embedded in app directory instead of agenix-managed secrets.

Current: Container running (Up 4 days), credentials at `/home/mba/docker/mounts/opus-stream-to-mqtt/app/.env` with Opus gateway and MQTT credentials.

## Solution

Migrate to agenix using Docker's `--env-file` option.

## Implementation

- [ ] Create `secrets/opus-stream-hsb1.age` with all credentials:
  - STREAM_USER, STREAM_PASS, STREAM_IP, STREAM_PORT (Opus gateway)
  - MQTT_BROKER, MQTT_TOPIC, MQTT_USER, MQTT_PASS (MQTT)
- [ ] Update `secrets/secrets.nix`: Add `"opus-stream-hsb1.age"` with hsb1 publicKeys
- [ ] Add to `hosts/hsb1/configuration.nix`:
  - `age.secrets.opus-stream-env` (owner: mba, mode: 0400)
- [ ] Update container startup: Use `--env-file /run/agenix/opus-stream-env`
- [ ] Deploy and restart container
- [ ] Verify container runs: `docker logs opus-stream-to-mqtt`
- [ ] Verify MQTT messages published
- [ ] Remove `.env` file from docker mounts directory

## Acceptance Criteria

- [ ] Secret created and encrypted
- [ ] secrets.nix updated
- [ ] configuration.nix updated
- [ ] Container uses agenix env file
- [ ] Stream functionality verified
- [ ] Plain-text .env removed

## Notes

- MQTT credentials here are separate from `mqtt.env` in `/etc/secrets/` (different service)
- Container currently managed manually via Docker CLI (not declarative)
- Consider combining with P5500 (Docker restructure) or P5700 (VLC kiosk declarative)
- Related: P6380-hsb1-agenix-secrets.md
