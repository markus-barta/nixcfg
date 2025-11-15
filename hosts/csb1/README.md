# csb1 - Cloud Server Barta 1

**Status**: ⚠️ Configuration extraction in progress  
**Type**: Cloud Server (Netcup VPS 1000 G11)  
**OS**: NixOS  
**Primary Domain**: cs1.barta.cm

---

## Overview

Cloud server hosting monitoring, documentation, and database services. Originally configured via nixos-anywhere.

---

## Server Information

### Network

- **Primary Domain**: cs1.barta.cm
- **IP Address**: 152.53.64.166
- **IPv6**: 2a0a:4cc0:80:2d5:e8e8:c7ff:fe68:03c7
- **FQDN**: v2202407214994279426.bestsrv.de
- **Provider**: Netcup VPS 1000 G11
- **Location**: Vienna (VIE)
- **Quick Connect**: `qc1` (fish abbreviation)

### Services

Based on 1Password entries, this server runs:

- **Grafana**: Multiple instances for different purposes
  - caroline grafana csb1 (user: caroline)
  - otto grafana csb1 (user: otto)
  - gerhard grafana csb1 (user: gerhard)
  - markus grafana csb1 (user: markus)
  - mailina grafana csb1 (user: mailina)
- **InfluxDB3**: Time series database
  - User: `admin`
- **Hedgedoc**: Collaborative markdown editor
  - Domain: hdoc.barta.cm
  - User: `hedgedoc`

---

## Backup Configuration

- **Backup Target**: Hetzner Storage Box
- **Method**: restic
- **Schedule**: TBD

---

## Access

### SSH Access

- Connect: `ssh mba@cs1.barta.cm` or `qc1`
- IP: `152.53.64.166`
- Local user password: Stored in 1Password ("cs1 csb1 qc1")
- Root password: Stored separately in 1Password

### Service Access

See encrypted secrets once secrets management is implemented.

---

## Current Status & TODOs

### ⚠️ Configuration Extraction Needed

1. Extract current NixOS configuration from live server:

   ```bash
   ssh mba@cs1.barta.cm "nixos-generate-config --show-hardware-config" > hardware-configuration.nix
   # Or via root: ssh root@152.53.64.166
   # Copy /etc/nixos/configuration.nix
   ```

2. Document current services and their configurations

3. Extract service credentials to secrets management:
   - Local user (mba) password: F0NyqFJD7rwmpct24c1
   - All Grafana user credentials (caroline, otto, gerhard, markus, mailina)
   - InfluxDB admin credentials
   - Hedgedoc credentials
   - Hetzner storage credentials

4. Create declarative configuration based on extracted data

5. Test deployment with nixos-anywhere

---

## SSH Key Fingerprints

### Current Installation

**ED25519**: `SHA256:XdDgST6kJOAsTOiiBCe04sEK5KbX1qDeS9DkeGAUa5s`  
**RSA**: `SHA256:FZiajhINn73JIXq5gCFWBdQLlwvPzLbHCyWcv5mdkJ4`  
**ECDSA**: `SHA256:U/94/tD0laaeI48MaxA0wqGE1LHq6OlBE3WH8jYN5OM`

---

## Related Services

- **node-RED** (csb0): Automation feeding data to Grafana
- **Mosquitto MQTT** (csb0): Data source for InfluxDB
- **Telegram Bot** (csb0): Notifications and alerts

---

## Migration Notes

### From 1Password to Secrets Management

Currently, credentials are scattered across multiple 1Password entries:

- "cs1 csb1 qc1" - Local mba user password
- Multiple "grafana csb1" entries (caroline, otto, gerhard, markus, mailina)
- "InfluxDB3 csb1" - Database admin
- "Hedgedoc barta.cm csb1 - hdoc.barta.cm"

Target: Consolidate into encrypted secrets structure:

```
~/Secrets/personal/encrypted/servers/csb1/
├── ssh-mba-user.env.age
├── grafana-users.env.age
├── influxdb-admin.env.age
├── hedgedoc-config.env.age
└── hetzner-backup.env.age
```

Keep in 1Password: Only emergency root recovery password.

---

## Network Configuration

### Original Installation Info

- **OS Options**: Debian 12 (bookworm) or Ubuntu 24.04 LTS
- **Current**: NixOS (custom installation via nixos-anywhere)
- **Root Password** (original): Stored in 1Password (not shown here)

---

## References

- [Secrets Management Architecture](../imac-mba-home/docs/reference/secrets-management.md)
- [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
- Netcup Customer Panel: [customercontrolpanel.de](https://www.customercontrolpanel.de/)
