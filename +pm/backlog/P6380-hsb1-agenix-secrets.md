# hsb1 Agenix Secrets Migration

**Created**: 2025-12-01  
**Updated**: 2026-01-06  
**Priority**: P6380 (Low)  
**Status**: Backlog  
**Host**: hsb1

---

## Problem

hsb1 still uses manually managed plain-text secrets in `/etc/secrets/` instead of agenix-encrypted secrets. This is inconsistent with the rest of the fleet and poses a minor security/maintenance risk.

**Current state** (verified 2026-01-06):

- Service `mqtt-volume-control` is running fine (active for 4+ days)
- Secrets are plain text files, manually managed
- hsb1 already has agenix set up for other secrets (`fritzbox-smb-credentials`, `nixfleet-token`)

---

## Current Secrets

| File              | Contents                        | Used By                     |
| ----------------- | ------------------------------- | --------------------------- |
| `mqtt.env`        | MQTT_HOST, MQTT_USER, MQTT_PASS | mqtt-volume-control service |
| `tapoC210-00.env` | TAPO_C210_PASSWORD              | mqtt-volume-control service |

---

## Solution

Migrate both secrets to agenix, maintaining the same file paths for backward compatibility.

### 1. Create Agenix Secrets

```bash
cd ~/Code/nixcfg

# MQTT credentials (use localhost since broker is local)
agenix -e secrets/mqtt-hsb1.age
# Contents:
# MQTT_HOST=localhost
# MQTT_USER=smarthome
# MQTT_PASS=<password from /etc/secrets/mqtt.env>

# Tapo camera credentials
agenix -e secrets/tapo-c210-00.age
# Contents:
# TAPO_C210_PASSWORD=<password from /etc/secrets/tapoC210-00.env>
```

### 2. Update secrets/secrets.nix

```nix
"mqtt-hsb1.age".publicKeys = [ mba hsb1 ];
"tapo-c210-00.age".publicKeys = [ mba hsb1 ];
```

### 3. Add to hosts/hsb1/configuration.nix

```nix
age.secrets = {
  mqtt-env = {
    file = ../../secrets/mqtt-hsb1.age;
    path = "/etc/secrets/mqtt.env";
    mode = "0400";
  };
  tapo-c210-00 = {
    file = ../../secrets/tapo-c210-00.age;
    path = "/etc/secrets/tapoC210-00.env";
    mode = "0400";
  };
};
```

---

## Acceptance Criteria

- [ ] Create `secrets/mqtt-hsb1.age` with MQTT credentials
- [ ] Create `secrets/tapo-c210-00.age` with camera password
- [ ] Update `secrets/secrets.nix` with new secrets
- [ ] Add `age.secrets` block to `hosts/hsb1/configuration.nix`
- [ ] Deploy and verify `mqtt-volume-control` still works
- [ ] Remove manual `/etc/secrets/` files from host

---

## Test Plan

### Manual Test

1. Deploy: `ssh mba@hsb1.lan 'cd ~/Code/nixcfg && git pull && just switch'`
2. Verify secrets: `ls -la /etc/secrets/`
3. Verify service: `systemctl status mqtt-volume-control`

### Automated Test

```bash
# Verify secrets are deployed via agenix (symlinks to /run/agenix/)
ssh mba@hsb1.lan 'ls -la /etc/secrets/'

# Verify service runs
ssh mba@hsb1.lan 'systemctl is-active mqtt-volume-control'
```

---

## Notes

- **Important**: Use `MQTT_HOST=localhost` (not hostname) since MQTT broker runs locally
- hsb1 SSH public key is already in `secrets/secrets.nix`

---

## Related

- `P6350-hsb1-runbook-secrets-complete.md` - Runbook secrets documentation
- `P5950-imac0-secrets-management.md` - Similar secrets migration for imac0
