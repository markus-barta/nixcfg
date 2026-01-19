# 🔐 Secrets Naming Pattern Guide

📍 **TL;DR:** Strict pattern: `host-function-subfunction.age`. Host prefix is mandatory for all host-specific secrets.

## 🎯 The Rule

**Always prefix with the target host.**

```text
Pattern: <host>-<function>[-<subfunction>].age
```

- **host**: csb0, hsb0, hsb1, hsb8, etc.
- **function**: mqtt, restic, mosquitto, traefik, etc.
- **subfunction**: (optional) env, conf, passwd, ssh-key, etc.

## 📋 Audit: Host-Specific Secrets

### ✅ Compliant (Host-Prefix)

| Secret File               | Host | Function | Subfunction |
| ------------------------- | ---- | -------- | ----------- |
| `hsb1-restic-env.age`     | hsb1 | restic   | env         |
| `hsb1-restic-ssh-key.age` | hsb1 | restic   | ssh-key     |

### ❌ Non-Compliant (Todo: Migration)

| Secret File                    | Current Pattern | Target Name                 | Host |
| ------------------------------ | --------------- | --------------------------- | ---- |
| `mqtt-csb0.age`                | function-host   | `csb0-mqtt-client.age`      | csb0 |
| `mqtt-hsb0.age`                | function-host   | `hsb0-mqtt-client.age`      | hsb0 |
| `static-leases-hsb0.age`       | function-host   | `hsb0-adguard-leases.age`   | hsb0 |
| `static-leases-hsb8.age`       | function-host   | `hsb8-adguard-leases.age`   | hsb8 |
| `mosquitto-conf.age`           | function-only   | `csb0-mosquitto-conf.age`   | csb0 |
| `mosquitto-passwd.age`         | function-only   | `csb0-mosquitto-passwd.age` | csb0 |
| `fritzbox-smb-credentials.age` | function-only   | `hsb1-fritzbox-smb.age`     | hsb1 |
| `nodered-env.age`              | function-only   | `csb0-nodered-env.age`      | csb0 |
| `ncps-key.age`                 | function-only   | `hsb0-ncps-key.age`         | hsb0 |
| `traefik-static.age`           | function-only   | `csb0-traefik-static.age`   | csb0 |
| `traefik-dynamic.age`          | function-only   | `csb0-traefik-dynamic.age`  | csb0 |
| `traefik-variables.age`        | function-only   | `csb0-traefik-env.age`      | csb0 |
| `uptime-kuma-env.age`          | function-only   | `csb0-uptime-kuma-env.age`  | csb0 |

## 🌐 Special Patterns

### Shared/Global Secrets

These apply to multiple hosts or the entire infrastructure. They use the `shared-` prefix to distinguish them from host-specific secrets and to group them together.

| Secret File                  | Scope  | Target Name                     | Description                       |
| ---------------------------- | ------ | ------------------------------- | --------------------------------- |
| `nixfleet-token.age`         | Global | `shared-nixfleet-token.age`     | Auth token for NixFleet dashboard |
| `restic-hetzner-env.age`     | Shared | `shared-restic-hetzner-env.age` | Shared Hetzner backup env         |
| `restic-hetzner-ssh-key.age` | Shared | `shared-restic-hetzner-ssh.age` | Shared Hetzner backup key         |

## 🔄 Migration Guide

### 1. Rename logic

Always use `git mv` to preserve history.

```bash
# Example: Mosquitto
git mv mosquitto-conf.age csb0-mosquitto-conf.age
git mv mosquitto-passwd.age csb0-mosquitto-passwd.age
```

### 2. Reference Update Order

1. **secrets.nix**: Update the key name (e.g., `"csb0-mosquitto-conf.age"`)
2. **host configuration**: Update `age.secrets.<name>.file` path.
3. **systemd/docker**: Update paths in service definitions or `EnvironmentFile`.

### 3. Finalize

Run `just rekey` immediately after renaming files.

## 🔄 Detailed Migration Plan (ToDo)

### Group 1: MQTT Client Credentials

| From            | To                     |
| --------------- | ---------------------- |
| `mqtt-csb0.age` | `csb0-mqtt-client.age` |
| `mqtt-hsb0.age` | `hsb0-mqtt-client.age` |

### Group 2: Mosquitto Broker Configuration

| From                   | To                          |
| ---------------------- | --------------------------- |
| `mosquitto-conf.age`   | `csb0-mosquitto-conf.age`   |
| `mosquitto-passwd.age` | `csb0-mosquitto-passwd.age` |

### Group 3: Global/Shared

| From                         | To                              |
| ---------------------------- | ------------------------------- |
| `nixfleet-token.age`         | `shared-nixfleet-token.age`     |
| `restic-hetzner-env.age`     | `shared-restic-hetzner-env.age` |
| `restic-hetzner-ssh-key.age` | `shared-restic-hetzner-ssh.age` |

## 📝 Benefits

- **Sortable**: `ls` groups secrets by host.
- **Predictable**: No guessing if host is prefix or suffix.
- **Sub-grouping**: `csb0-traefik-*` groups all traefik secrets for that host.

📍 **TL;DR:** Standards enforced. Host first. Migration table updated.
