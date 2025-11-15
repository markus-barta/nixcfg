# csb0 - Cloud Server Barta 0

**Status**: ⚠️ Configuration extraction in progress  
**Type**: Cloud Server (Netcup VPS)  
**OS**: NixOS  
**Primary Domain**: cs0.barta.cm

---

## Overview

Cloud server for various services and automation. Originally configured via nixos-anywhere.

---

## Server Information

### Network

- **Primary Domain**: cs0.barta.cm
- **Provider**: Netcup VPS
- **Location**: TBD

### Services

Based on 1Password entries and DNS records, this server runs:

- **node-RED**: Automation and workflow engine
  - User: `admin`
  - Purpose: IoT automation, integrations
- **Telegram Bot**: csb0bot
  - Bot URL: t.me/csb0bot
  - Purpose: Notifications, remote control
- **Mosquitto MQTT**: Message broker
  - Domain: mosquitto.barta.cm
  - User: `smarthome`
  - Purpose: IoT device communication
- **Bitwarden**: Password manager instance
  - Domain: bitwarden.barta.cm
  - Purpose: Self-hosted password management
- **Traefik**: Reverse proxy
  - Domain: traefik.barta.cm
  - Purpose: Service routing and SSL termination
- **NodeRED**: Smart home platform
  - Domain: home.barta.cm
  - Purpose: Home automation coordination
- **WhoAmI**: Test/debug service
  - Domain: whoami0.barta.cm
  - Purpose: Service testing

---

## Backup Configuration

- **Backup Target**: Hetzner Storage Box
- **Method**: restic
- **Schedule**: TBD

---

## Access

### SSH Access

- Connect via: Standard SSH with your personal key
- Users: `mba` (local user), `root` (admin)

### Service Access

See encrypted secrets once secrets management is implemented.

---

## Current Status & TODOs

### ⚠️ Configuration Extraction Needed

1. Extract current NixOS configuration from live server:

   ```bash
   ssh root@cs0.barta.cm "nixos-generate-config --show-hardware-config" > hardware-configuration.nix
   # Copy /etc/nixos/configuration.nix
   ```

2. Document current services and their configurations

3. Extract service credentials to secrets management:
   - node-RED admin credentials
   - Telegram bot token (csb0bot)
   - Mosquitto MQTT credentials
   - Hetzner storage credentials

4. Create declarative configuration based on extracted data

5. Test deployment with nixos-anywhere

---

## Related Services

- **Grafana** (csb1): Monitoring and visualization
- **Hedgedoc** (csb1): Collaborative markdown editor at hdoc.barta.cm
- **InfluxDB** (csb1): Time series database

---

## Migration Notes

### From 1Password to Secrets Management

Currently, credentials are scattered across multiple 1Password entries:

- "node-RED csb0"
- "Telegram bot csb0"
- "mosquitto - mqtt"

Target: Consolidate into encrypted secrets structure:

```
~/Secrets/personal/encrypted/servers/csb0/
├── node-red-admin.env.age
├── telegram-bot-token.env.age
├── mqtt-credentials.env.age
└── hetzner-backup.env.age
```

Keep in 1Password: Only emergency root recovery password.

---

## References

- [Secrets Management Architecture](../imac-mba-home/docs/reference/secrets-management.md)
- [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
