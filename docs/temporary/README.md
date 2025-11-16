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

**Context**: Configuring msww87 Mac mini at parents' home with location-based config

- **ip-100-investigation-summary.md** - IP address investigation (✅ 192.168.1.100 approved)
- **msww87-server-notes.md** - Detailed system analysis and hardware specifications
- **msww87-setup-steps.md** - Step-by-step static IP configuration guide
- **msww87-ssh-key-gerhard.md** - Gerhard's SSH key configuration (✅ added, deployed)
- **msww87-repo-switch-guide.md** - Safe migration from pbek/nixcfg to markus-barta/nixcfg (✅ completed)
- **msww87-enable-ww87-script.md** - One-command deployment script for parents' home (✅ ready)

**Current Status** (✅ Deployed):

- Hostname: `msww87` (renamed from mba-msww87)
- Static IP: `192.168.1.100`
- Location: `jhw22` (testing at Markus' home)
- Ready for parents' home: Run `enable-ww87` on the server

**Key Findings**:

- MAC `40:6c:8f:18:dd:24` matches old "miniserver" - this machine previously held .100
- Gerhard's SSH public key configured for `gb` user account
- Interface is `enp2s0f0` (not `enp3s0f0` as noted in hardware-config comments)
- Location-based configuration switches network settings and enables AdGuard Home

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
