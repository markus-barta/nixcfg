# agenix-secrets

**Host**: hsb1
**Priority**: P63
**Status**: Backlog
**Created**: 2025-12-01
**Updated**: 2026-01-06

---

## Problem

hsb1 uses manually managed plain-text secrets in `/etc/secrets/` instead of agenix. Inconsistent with fleet and poses security/maintenance risk.

Current: `mqtt-volume-control` service running fine (4+ days), but secrets are plain text files.

## Solution

Migrate MQTT and Tapo camera credentials to agenix, maintaining same file paths for backward compatibility.

## Implementation

- [ ] Create `secrets/mqtt-hsb1.age` with MQTT credentials (MQTT_HOST=localhost, user, pass)
- [ ] Create `secrets/tapo-c210-00.age` with camera password
- [ ] Update `secrets/secrets.nix`: Add `"mqtt-hsb1.age"` and `"tapo-c210-00.age"` with hsb1 publicKeys
- [ ] Add to `hosts/hsb1/configuration.nix`:
  - `age.secrets.mqtt-env` → `/etc/secrets/mqtt.env` (mode 0400)
  - `age.secrets.tapo-c210-00` → `/etc/secrets/tapoC210-00.env` (mode 0400)
- [ ] Deploy: `ssh mba@hsb1.lan 'cd ~/Code/nixcfg && git pull && just switch'`
- [ ] Verify secrets deployed: `ls -la /etc/secrets/` (symlinks to /run/agenix/)
- [ ] Verify service works: `systemctl status mqtt-volume-control`
- [ ] Remove manual `/etc/secrets/` files from host

## Acceptance Criteria

- [ ] Both secrets created and encrypted with agenix
- [ ] secrets.nix updated
- [ ] configuration.nix updated with age.secrets blocks
- [ ] Service `mqtt-volume-control` still works after deployment
- [ ] Manual plain-text files removed

## Notes

- Current secrets:
  - `mqtt.env`: MQTT_HOST, MQTT_USER, MQTT_PASS (for mqtt-volume-control)
  - `tapoC210-00.env`: TAPO_C210_PASSWORD (for mqtt-volume-control)
- **Important**: Use `MQTT_HOST=localhost` (broker runs locally on hsb1)
- hsb1 SSH public key already in `secrets/secrets.nix`
- Related: P6350-hsb1-runbook-secrets-complete.md
