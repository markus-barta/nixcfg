# Temporary Documentation

⚠️ **SECURITY UPDATE (Nov 18, 2025)**: Sensitive documentation moved to gitignored location

---

## 🚨 Repository Security Incident

**Date**: November 18, 2025  
**Issue**: Repository was made public with sensitive data in git history

**Sensitive files moved to**: `docs/migration-2025-11/` (gitignored)

Files that contained sensitive information have been relocated:

- ~~`PICK-UP-HERE.md`~~ → `docs/migration-2025-11/secrets-migration/status.md`
- ~~`dns-barta-cm.md`~~ → `docs/migration-2025-11/dns-records.md`
- `secrets-migration-plan.md` → `docs/migration-2025-11/secrets-migration/plan.md`

**Action Required**:

1. Clean git history to remove exposed data
2. Rotate exposed credentials (csb1 SSH password)
3. Verify repo security

---

## Current Contents

This folder now contains only:

### Active (Safe to Commit)

- **README.md** (this file) - Directory index and security notice
- **secrets-migration-plan.md** - Template/planning doc (no actual secrets)

### Archived (Safe)

- **archived/** - Old msww87 setup documentation (no sensitive data)

---

## Migration to Permanent Locations

### msww87 Server Setup ✅ COMPLETED

**Status**: All configuration files moved to `hosts/msww87/README.md`

**Documentation Location**:

- Main documentation: `hosts/msww87/README.md`
- Deployment script guide: `hosts/msww87/enable-ww87.md`
- Archived setup guides: `archived/` subdirectory

### November 2025 Migrations ⏳ IN PROGRESS

**All sensitive documentation consolidated to**: `docs/migration-2025-11/`

**Includes**:

1. CSB server migrations (csb0, csb1)
2. Secrets management migration (1Password → agenix)
3. Zellij configuration recovery
4. DNS infrastructure documentation

**See**: `docs/migration-2025-11/README.md` for complete index

---

## Temporary vs Permanent Documentation

**Permanent docs** (in `docs/` root):

- `how-it-works.md` - Bird's eye view of the system
- `overview.md` - Technical reference and workflows
- `hokage-options.md` - Generated module options reference

**Sensitive docs** (gitignored):

- `docs/migration-2025-11/` - Active migration work with server details
- `docs/investigation-private/` - Zellij investigation (also in migration-2025-11)
- `hosts/*/secrets/` - Per-host operational documentation

**Temporary docs** (this folder):

- Planning templates (no actual secrets)
- Archived completed projects
- Safe reference material

---

## Security Policy

### What Goes Where

**Commit to git** (public/safe):

- ✅ NixOS configurations (without secrets)
- ✅ Documentation of processes
- ✅ Templates and examples
- ✅ Architecture overviews (generalized)

**Gitignore** (sensitive):

- 🔒 Server IPs and infrastructure details
- 🔒 Access credentials (even if they should be rotated)
- 🔒 Service configurations with real data
- 🔒 Investigation findings
- 🔒 Migration planning with actual values

**Agenix encrypt** (secrets for systems):

- 🔐 Service passwords
- 🔐 API keys and tokens
- 🔐 Private keys
- 🔐 Database credentials

---

## Next Steps

Once a task is complete, temporary docs should be:

1. **Archived** to a project history doc (if valuable)
2. **Deleted** if no longer relevant
3. **Moved** to permanent docs if containing safe reference material
4. **Never commit** if containing sensitive operational details

---

**Last Updated**: November 18, 2025  
**Status**: Security cleanup in progress  
**See**: `docs/migration-2025-11/README.md` for active work
