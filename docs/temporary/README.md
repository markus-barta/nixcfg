# Temporary Documentation

This folder contains temporary documentation files that are:

- Work in progress
- Planning documents
- Migration notes
- Temporary backups

These files may be moved to proper documentation locations, archived, or deleted once their purpose is complete.

## Current Contents

### Active Projects

- **PICK-UP-HERE.md** - Active TODO tracker for secrets management migration
- **dns-barta-cm.md** - DNS record inventory and Terraform migration plan
- **secrets-migration-plan.md** - Step-by-step secrets migration guide

### msww87 Server Setup (November 16, 2025)

**Status**: ✅ **COMPLETED** - All configuration files moved to `hosts/msww87/README.md`

**Context**: Mac mini 2011 configured as parents' home automation server with location-based configuration.

**Deployed Configuration**:

- Hostname: `msww87` (renamed from mba-msww87)
- Static IP: `192.168.1.100`
- Location: `jhw22` (testing at Markus' home)
- Ready for parents' home: Run `enable-ww87` on the server

**Documentation Archived**:

- All setup notes consolidated into `hosts/msww87/README.md`
- Archived step-by-step guides in `archived/` subdirectory
- enable-ww87 script documentation: `msww87-enable-ww87-script.md`

**See**: `hosts/msww87/README.md` for complete documentation

## Temporary vs Permanent Documentation

**Permanent docs** (in `docs/` root):

- `how-it-works.md` - Bird's eye view of the system
- `overview.md` - Technical reference and workflows
- `hokage-options.md` - Generated module options reference

**Temporary docs** (in `docs/temporary/`):

- Active project notes
- Migration checklists
- Planning documents
- DNS/infrastructure inventories before automation

Once a task is complete, temporary docs should be:

1. Archived to a project history doc
2. Deleted if no longer relevant
3. Moved to permanent docs if containing valuable reference material
