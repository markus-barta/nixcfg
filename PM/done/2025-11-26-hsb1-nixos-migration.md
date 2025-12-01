# 2025-11-26 - hsb1 NixOS Migration (miniserver24 → hsb1)

## Description

Rename hostname and migrate to external hokage consumer pattern.

## Source

- Original: `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md` (Part A: Phases 1-4, 7-9)
- Split from: `2025-11-26-hsb1-full-migration.md`

## Scope

Applies to: hsb1 (formerly miniserver24)

## Acceptance Criteria

- [x] Hostname renamed: miniserver24 → hsb1
- [x] External hokage consumer pattern applied
- [x] SSH key security (lib.mkForce) applied
- [x] Passwordless sudo configured
- [x] MQTT topic updated to `home/hsb1/...`
- [x] DHCP/DNS updates on hsb0 (static lease)
- [x] System deployed and running
- [x] Docker containers running post-migration

## Implementation Details

| Item              | Location                     |
| ----------------- | ---------------------------- |
| Hostname = hsb1   | `configuration.nix` L314     |
| External hokage   | `configuration.nix` L313-329 |
| SSH lib.mkForce   | `configuration.nix` L332-349 |
| Passwordless sudo | `configuration.nix` L354     |
| MQTT topic        | `configuration.nix` L271     |

## Test Results

- Manual test: [x] Pass
- Automated test: [x] Pass
- Date verified: 2025-11-26

## Notes

- Applied lessons from hsb8 SSH lockout incident (2025-11-22)
- Server is running as `hsb1` with all Docker services operational
