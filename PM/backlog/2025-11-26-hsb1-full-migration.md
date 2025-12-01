# 2025-11-26 - hsb1 Full Migration (miniserver24 → hsb1)

## Description

Complete migration of miniserver24 to hsb1 including hostname rename, external hokage consumer pattern, and file restructure.

## Source

- Original: `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md`
- Status at extraction: 📋 PLANNING

## Scope

Applies to: hsb1 (formerly miniserver24)

## Acceptance Criteria

### Part A: NixOS Migration

- [ ] Hostname renamed: miniserver24 → hsb1
- [ ] External hokage consumer pattern applied
- [ ] DHCP/DNS updates on hsb0
- [ ] System secrets migrated to agenix
- [ ] SSH key security (lib.mkForce) applied
- [ ] All 11 Docker containers running post-migration

### Part B: File Restructure

- [ ] Docker config consolidated into main repo
- [ ] User scripts consolidated into main repo
- [ ] Symlinks set up as "signposts"
- [ ] Separate ~/docker git repo retired

## Notes

- Risk Level: 🟠 HIGH - 133 Zigbee devices, HomeKit, cameras
- Estimated Duration: ~6 hours total (split over 2 days recommended)
- Detailed migration plan available in `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md`
- Lessons from hsb8 SSH lockout incident must be applied
