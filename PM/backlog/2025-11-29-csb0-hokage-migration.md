# 2025-11-29 - csb0 External Hokage Migration

## Description

Migrate csb0 (Cloud Server Barta 0) from local modules/mixins to external hokage consumer pattern using `github:pbek/nixcfg`.

## Source

- Original: `hosts/csb0/docs/MIGRATION-PLAN-HOKAGE.md`
- Status at extraction: 🟡 PLANNED (after csb1 success)

## Scope

Applies to: csb0 (smart home automation, IoT hub, MQTT broker)

## Acceptance Criteria

- [ ] Configuration preparation complete
- [ ] SSH key security (lib.mkForce) applied
- [ ] Temporary password auth enabled during migration
- [ ] External hokage pattern active
- [ ] All 8 Docker containers running
- [ ] MQTT broker operational (csb1 depends on this!)
- [ ] Backup manager verified (manages BOTH servers)
- [ ] Full reboot verified

## Notes

- Risk Level: 🟠 MEDIUM-HIGH - Smart home & IoT critical services
- 267+ days uptime (very stable server)
- **Critical**: csb0 provides MQTT to csb1 - cross-server dependency
- Services: Node-RED, MQTT/Mosquitto, Telegram Bot (garage door), Traefik, Cypress, Backup/Restic
- Apply all lessons from csb1 migration (lib.mkForce SSH keys, temp password auth)
- Detailed plan in `hosts/csb0/docs/MIGRATION-PLAN-HOKAGE.md`
