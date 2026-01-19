# P4502 - Analyze and Migrate Legacy Mosquitto Secrets

**Task:** Investigation and potential migration of `mosquitto-conf.age` and `mosquitto-passwd.age`.
**Status:** Investigation Complete - Distinct Formats Identified
**Priority:** P6 (Medium - Naming Alignment Only)

## Context

During the restoration of corrupted age files on 2026-01-17, two mosquitto-related files were identified that seemed to follow a legacy or non-standard pattern:

- `secrets/mosquitto-conf.age` (1.0k)
- `secrets/mosquitto-passwd.age` (702B)

## Investigation Findings ✅

### The "Two Pattern" Reality

The investigation confirmed that these are **not redundant**, but serve two fundamentally different technical roles:

#### 1. The Broker Configuration (Server-Side)

- **Files**: `mosquitto-conf.age`, `mosquitto-passwd.age`
- **Role**: **Broker Logic.** These are raw configuration files required for the MQTT server to exist.
- **Usage**: Mounted as Docker volumes in `hosts/csb0/docker/docker-compose.yml`.
- **Format**: Raw `.conf` and binary/formatted password file. **Cannot be converted to KEY=VALUE.**

#### 2. The Service Credentials (Client-Side)

- **Files**: `mqtt-csb0.age`, `mqtt-hsb0.age`
- **Role**: **Client Logic.** These allow services (Node-RED, UPS monitoring) to authenticate with the broker.
- **Usage**: Referenced as `EnvironmentFile` in NixOS systemd services.
- **Format**: `KEY=VALUE` environment variables.

### Conclusion: No Format Migration

We **cannot** merge the broker config into the client env files. They must remain separate files because the Mosquitto container expects raw configuration files.

## Recommendations

### ✅ Renaming for Pattern Alignment

To follow the `host-function-subfunction.age` standard, these should be renamed to clearly indicate they are **csb0 broker** files:

| Current Name           | Target Name                 | Reason                      |
| ---------------------- | --------------------------- | --------------------------- |
| `mosquitto-conf.age`   | `csb0-mosquitto-conf.age`   | Specific to csb0 broker     |
| `mosquitto-passwd.age` | `csb0-mosquitto-passwd.age` | Specific to csb0 broker     |
| `mqtt-csb0.age`        | `csb0-mqtt-client.age`      | Clarifies client-side usage |

## 🔄 Migration Plan (ToDo)

1. **Rename Files**: `git mv` the files in `secrets/`.
2. **Update `secrets/secrets.nix`**: Map new filenames to host keys.
3. **Update `hosts/csb0/configuration.nix`**: Update the `age.secrets` references.
4. **Update `hosts/csb0/docker/docker-compose.yml`**: Update volume mount paths (e.g., `/run/agenix/csb0-mosquitto-conf`).
5. **Update `docs/SECRETS.md`**: Reflect the "Broker vs Client" distinction in the guide.

## Meta

- **Origin**: Discovery during secret restoration on 2026-01-17.
- **Audit**: Verified vs `csb0` docker-compose and systemd service configs.
