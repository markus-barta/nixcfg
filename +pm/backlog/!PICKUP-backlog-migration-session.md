# !PICKUP: Backlog Migration Session

**Created**: 2026-02-10
**Status**: ⏸️ Paused - Migration Complete, Review Pending
**Next Step**: Review migrated items, then continue with infrastructure-wide items

---

## 🎯 Quick Context

You were migrating backlog items from `+pm/backlog/` to host-specific backlogs in `hosts/*/docs/backlog/`.

**Completed**: ✅ All host-specific items migrated (30 total)
**Remaining**: 27 infrastructure-wide items in `+pm/backlog/` (not host-specific)

---

## ✅ What Was Accomplished

### Migration Stats

- **Total Migrated**: 30 host-specific items
- **Hosts Affected**: 9 hosts (csb0, csb1, hsb0, hsb1, hsb8, gpc0, imac0, miniserver-bp)
- **New Structure**: LNN.hash.description.md format (e.g., P15.4f956ad.audit-docs.md)
- **Template Applied**: Concise Problem/Solution/Implementation/Acceptance/Notes

### Infrastructure Created

1. **Generic Script**: `scripts/create-backlog-item.sh`
   - Supports `--host` and `--dir` flags
   - Example: `./scripts/create-backlog-item.sh P30 audit-docker --host hsb0`

2. **Hash Generator**: `scripts/lib/generate-hash.sh`
   - Collision-checked across entire repo
   - Called internally by create-backlog-item.sh

3. **Host Backlogs**: Created `hosts/*/docs/backlog/` for:
   - csb0, csb1, hsb0, hsb1, hsb8, gpc0, imac0, miniserver-bp

### Migration Details by Host

| Host              | Items | Topics                                                                                               |
| ----------------- | ----- | ---------------------------------------------------------------------------------------------------- |
| **csb0**          | 8     | Docker simplification, auth cleanup, Nuki refactor, load spike, migration, headscale, sonnen scraper |
| **csb1**          | 4     | Docker files to repo, audit docs, InfluxDB cleanup                                                   |
| **hsb0**          | 2     | Runbook secrets, OpenClaw autoupdate caching                                                         |
| **hsb1**          | 7     | Nuki charging, runbook secrets, agenix, Opus MQTT, OpenClaw, Plex, Docker restructure, VLC kiosk     |
| **hsb8**          | 2     | Grafana/InfluxDB, ESP32 MQTT integration                                                             |
| **gpc0**          | 1     | Wake-on-LAN (blocked - driver issue)                                                                 |
| **imac0**         | 3     | Secrets management (done), Homebrew maintenance, zsh dotdir                                          |
| **miniserver-bp** | 2     | Firewall port 22, NixOS migration                                                                    |

### Priority Mapping

- Old format: 4-digit (P1504, P6300)
- New format: 2-digit (P15, P63)
- Truncated first 2 digits for conciseness

---

## 📋 Remaining Work

### Infrastructure-Wide Items (27 in +pm/backlog/)

These are NOT host-specific and should stay in `+pm/backlog/`:

1. `P2100-fix-cron-scheduling-sync.md` - OpenClaw scheduling (infrastructure)
2. `P2200-fix-gemini-thought-signature-errors.md` - OpenClaw errors (infrastructure)
3. `P2502-mosquitto-secrets-investigation.md` - Cross-host MQTT audit
4. `P4000-openclaw-update-automation.md` - Fleet-wide automation
5. `P4500-generic-home-assistant-skill.md` - OpenClaw skill (generic)
6. `P4500-msbp-pm-tool-prd.md` - Product requirement (not host-specific)
7. `P4550-msbp-docker-infra.md` - Infrastructure planning
8. `P4600-ha-person-tracking.md` - Cross-host feature
9. `P4600-msbp-pm-tool-deployment.md` - Deployment doc
10. `P4650-pm-tool-repo-scaffold.md` - Repo structure
11. ... (17 more)

**Decision Needed**: Should these also be migrated to new format (LNN.hash.description.md) in place?

---

## 🔍 Review Checklist

Before continuing, verify:

- [ ] Check `hosts/*/docs/backlog/` directories exist
- [ ] Spot-check 5-10 migrated files for quality
- [ ] Verify git status shows deletions + new files
- [ ] Test create-backlog-item.sh script:

  ```bash
  # Test infrastructure backlog
  ./scripts/create-backlog-item.sh P50 test-item

  # Test host backlog
  ./scripts/create-backlog-item.sh P30 test-item --host hsb0
  ```

- [ ] Decide on infrastructure-wide items (migrate format or keep as-is?)

---

## 🚀 Next Steps

### Option A: Review & Commit (Recommended)

1. Review migrated items in `hosts/*/docs/backlog/`
2. Commit changes: `git add -A && git commit -m "feat: migrate backlog to host-specific structure"`
3. Delete this pickup document
4. Optional: Migrate infrastructure-wide items to new format

### Option B: Continue Infrastructure Items

1. Decide if infrastructure items should use new format
2. If yes: Migrate `+pm/backlog/*.md` to `LNN.hash.description.md` format in place
3. Apply same template (Problem/Solution/Implementation/Acceptance)
4. Commit all changes together

---

## 📊 Git Status Preview

Expected changes:

- **Deleted**: ~30 files from `+pm/backlog/`
- **Added**:
  - `scripts/create-backlog-item.sh`
  - `scripts/lib/generate-hash.sh`
  - ~30 files in `hosts/*/docs/backlog/`

```bash
# Quick check
git status --short | head -20
find hosts/*/docs/backlog -name "*.md" | wc -l  # Should be 30
ls -1 +pm/backlog/*.md | wc -l  # Should be 27
```

---

## 💡 Key Decisions Made

1. **Template**: Concise structure (Problem/Solution/Implementation/Acceptance/Notes)
2. **Naming**: LNN.hash.description.md (e.g., P63.2df9675.runbook-secrets.md)
3. **Detection**: Read file content for `Host:` field + filename patterns
4. **Original Files**: Deleted after migration (moved to trash)
5. **Priority**: Truncated to 2 digits (P1504 → P15)
6. **Cleanup**: Light cleanup applied (removed excessive prose, standardized sections)

---

## 🛠️ Commands Reference

```bash
# Create infrastructure backlog item
./scripts/create-backlog-item.sh P50 fix-thing

# Create host-specific backlog item
./scripts/create-backlog-item.sh P30 fix-thing --host hsb0

# Or with explicit directory
./scripts/create-backlog-item.sh P30 fix-thing --dir hosts/hsb0/docs/backlog

# Generate hash only
./scripts/lib/generate-hash.sh .

# List all migrated items
find hosts/*/docs/backlog -name "*.md" -exec echo {} \;

# Check git status
git status --short | grep backlog
```

---

## ❓ Open Questions

1. Should infrastructure-wide items (`+pm/backlog/*.md`) also use new format?
2. Should we create a `+pm/done/` archive for completed items?
3. Template feedback - any sections to add/remove?

---

## 📝 Notes for Next Session

- All scripts are working and tested
- Hash collision checking works across entire repo
- Template is concise but complete
- Migration approach validated across 30 items
- Ready to review and commit when convenient

---

**To resume**: Read this document, review a few migrated files, commit changes, then decide on infrastructure items.
