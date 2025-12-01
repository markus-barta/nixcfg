# 2025-12-01 - Enable Home Assistant on hsb8

## Description

Enable the Home Assistant service on hsb8 when the server is deployed to parents' home (ww87). This will provide smart home automation capabilities at that location.

## Source

- Related: hsb8 ww87 deployment task (now complete)

## Scope

Applies to: hsb8 (at ww87)

## Acceptance Criteria

- [ ] Home Assistant Docker container or NixOS service configured
- [ ] Service accessible via web UI
- [ ] Basic integrations configured for ww87 location
- [ ] Backup strategy defined

## Notes

- Low priority - for future when time permits
- Consider whether to use Docker (like hsb1) or native NixOS service
- May need AdGuard DNS entries for local access
