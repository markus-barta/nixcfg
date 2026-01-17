# P4502 - Analyze and Migrate Legacy Mosquitto Secrets

**Task:** Investigation and potential migration of `mosquitto-conf.age` and `mosquitto-passwd.age`.
**Status:** Pending
**Priority:** P8 (Backlog)

## Context

During the restoration of corrupted age files on 2026-01-17, two mosquitto-related files were identified that seem to follow a legacy or non-standard pattern:

- `secrets/mosquitto-conf.age` (1.0k)
- `secrets/mosquitto-passwd.age` (702B)

The user noted these as "strange" and wants to understand their current usage before potentially migrating them to the newer `mqtt-csb0.age` or `mqtt-hsb0.age` patterns.

## Goals

- [ ] Identify which hosts/modules reference these files.
- [ ] Determine if the content is still relevant or if it has been replaced by the new `mqtt-csb0.age`.
- [ ] If redundant, remove the files and update references.
- [ ] If still needed, document their purpose and ensure they are properly rekeyed.

## Files to Investigate

- `secrets/mosquitto-conf.age`
- `secrets/mosquitto-passwd.age`
- `modules/` (search for references)
- `hosts/csb0/` (search for references)

## Meta

- **Origin:** Discovery during secret restoration on 2026-01-17.
- **Effort:** Low (1 hour research).
