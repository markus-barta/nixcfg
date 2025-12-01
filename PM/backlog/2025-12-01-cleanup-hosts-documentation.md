# 2025-12-01 - Cleanup: Hosts Documentation Inconsistencies

## Description

Fix documentation inconsistencies in hosts/ directory related to migration statuses and hostname references.

## Source

- Discovered during PM sweep

## Scope

Applies to: hosts/ directory documentation

## Findings

### hosts/README.md

- May reference gpc0 migration as "pending" (now COMPLETE per gpc0/docs)
- Check all host migration statuses are current

### hosts/DEPLOYMENT.md

- Shows gpc0 with old hostname `mba-gaming-pc` in Nix system section
- Needs update to reflect gpc0 completion

### hosts/gpc0/docs/MIGRATION-PLAN-HOKAGE.md

- Status: ✅ COMPLETE
- Lessons learned section is comprehensive

### hosts/hsb1/docs/

- MIGRATION-PLAN-HSB1.md shows status as 📋 PLANNING
- SMARTHOME.md references migration complete (2025-11-28)
- DNS alias note: "miniserver24 still resolves (legacy, remove after 2025-12-28)"

### hosts/csb1/docs/MIGRATION-PLAN-HOKAGE.md

- Status: ✅ COMPLETE (2025-11-29)
- Post-migration notes section partially empty ("_To be filled_")

## Acceptance Criteria

- [ ] Update hosts/README.md with current migration statuses
- [ ] Update hosts/DEPLOYMENT.md gpc0 section
- [ ] Verify all migration plan status markers are accurate
- [ ] Fill in empty post-migration notes where applicable
- [ ] Check DNS alias removal date for hsb1 (after 2025-12-28)

## Notes

- Some migrations may be in progress - verify current state before updating
- Migration plans in archive/ should be left as-is for historical reference
