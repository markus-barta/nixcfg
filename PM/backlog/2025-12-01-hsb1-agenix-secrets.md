# 2025-12-01 - hsb1 Agenix Secrets Migration

## Description

Migrate hsb1 system secrets from plain `/etc/secrets/` files to agenix-encrypted secrets.

## Source

- Original: `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md` (Phase 5)
- Split from: `2025-11-26-hsb1-full-migration.md`

## Scope

Applies to: hsb1

## Current State

Secrets currently in `/etc/secrets/` (plain text, manually managed):

| File              | Contents                        | Used By                     |
| ----------------- | ------------------------------- | --------------------------- |
| `mqtt.env`        | MQTT_HOST, MQTT_USER, MQTT_PASS | mqtt-volume-control service |
| `tapoC210-00.env` | TAPO_C210_PASSWORD              | mqtt-volume-control service |

## Acceptance Criteria

- [ ] Create `secrets/mqtt-hsb1.age` with MQTT credentials
- [ ] Create `secrets/tapo-c210-00.age` with camera password
- [ ] Update `secrets/secrets.nix` with hsb1 public key
- [ ] Add `age.secrets` block to `hosts/hsb1/configuration.nix`
- [ ] Deploy and verify services still work
- [ ] Remove manual `/etc/secrets/` files

## Implementation

### 1. Create Agenix Secrets

```bash
cd ~/Code/nixcfg

agenix -e secrets/mqtt-hsb1.age
# Contents:
# MQTT_HOST=hsb1
# MQTT_USER=smarthome
# MQTT_PASS=<password from /etc/secrets/mqtt.env>

agenix -e secrets/tapo-c210-00.age
# Contents:
# TAPO_C210_PASSWORD=<password from /etc/secrets/tapoC210-00.env>
```

### 2. Update secrets/secrets.nix

```nix
"mqtt-hsb1.age".publicKeys = [ mba hsb1 ];
"tapo-c210-00.age".publicKeys = [ mba hsb1 ];
```

### 3. Add to configuration.nix

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

## Test Plan

### Manual Test

1. Deploy configuration: `just switch`
2. Verify secrets exist: `ls -la /etc/secrets/`
3. Verify mqtt-volume-control works: `systemctl status mqtt-volume-control`
4. Test MQTT volume control via topic

### Automated Test

```bash
# Verify secrets are deployed
ssh mba@hsb1.lan 'test -f /etc/secrets/mqtt.env && echo "✅ mqtt.env" || echo "❌ mqtt.env"'
ssh mba@hsb1.lan 'test -f /etc/secrets/tapoC210-00.env && echo "✅ tapo.env" || echo "❌ tapo.env"'

# Verify service runs
ssh mba@hsb1.lan 'systemctl is-active mqtt-volume-control'
```

## Notes

- Must have hsb1 SSH public key in secrets.nix before encrypting
- Coordinate with `2025-11-29-secrets-directory-restructure.md` for overall secrets strategy
