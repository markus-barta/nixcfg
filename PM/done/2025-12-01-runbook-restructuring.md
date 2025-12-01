# 2025-12-01 - Runbook Restructuring

## Description

Restructure runbooks across all hosts to:

1. Move runbooks from central `docs/` to host directories
2. Separate operational procedures from secrets
3. Create SECRETS.md files for emergency access credentials
4. Deprecate old runbooks that had inline secrets

## Source

- Original: Conversation about documentation structure (December 2025)
- Status at extraction: Completed

## Scope

Applies to: All hosts (hsb0, hsb1, csb0, csb1, hsb8, gpc0, imac0, imac-mba-work)

## What Was Done

### Structure Changes

| Change                  | Description                                               |
| ----------------------- | --------------------------------------------------------- |
| Moved central runbooks  | `docs/RUNBOOK-*.md` → `hosts/<hostname>/docs/RUNBOOK.md`  |
| Created clean runbooks  | Cloud servers got new runbooks without inline secrets     |
| Deprecated old runbooks | `hosts/csb*/secrets/RUNBOOK.md` → `DEPRECATED-RUNBOOK.md` |
| Created SECRETS.md      | All hosts now have `secrets/SECRETS.md` for credentials   |

### Files Created/Modified

**Runbooks Created/Moved:**

- `hosts/hsb0/docs/RUNBOOK.md` - Moved from `docs/`
- `hosts/hsb1/docs/RUNBOOK.md` - Moved from `docs/`
- `hosts/csb0/docs/RUNBOOK.md` - Created (clean, no secrets)
- `hosts/csb1/docs/RUNBOOK.md` - Created (clean, no secrets)
- `hosts/hsb8/docs/RUNBOOK.md` - Created
- `hosts/gpc0/docs/RUNBOOK.md` - Created
- `hosts/imac0/docs/RUNBOOK.md` - Created
- `hosts/imac-mba-work/docs/RUNBOOK.md` - Created

**SECRETS.md Created:**

- `hosts/csb0/secrets/SECRETS.md` - Complete (all credentials)
- `hosts/csb1/secrets/SECRETS.md` - Complete (all credentials)
- `hosts/hsb0/secrets/SECRETS.md` - Template
- `hosts/hsb1/secrets/SECRETS.md` - Template
- `hosts/hsb8/secrets/SECRETS.md` - Template
- `hosts/gpc0/secrets/SECRETS.md` - Template
- `hosts/imac0/secrets/SECRETS.md` - Template
- `hosts/imac-mba-work/secrets/SECRETS.md` - Template

**Deprecated:**

- `hosts/csb0/secrets/DEPRECATED-RUNBOOK.md` - Old runbook with secrets
- `hosts/csb1/secrets/DEPRECATED-RUNBOOK.md` - Old runbook with secrets

**Deleted:**

- `docs/RUNBOOK-hsb0.md` - Moved to host directory
- `docs/RUNBOOK-hsb1.md` - Moved to host directory

## Acceptance Criteria

- [x] All hosts have `docs/RUNBOOK.md` for operational procedures
- [x] All hosts have `secrets/SECRETS.md` for credentials
- [x] Runbooks do not contain secrets (passwords, tokens, etc.)
- [x] Cloud server runbooks extracted all secrets to SECRETS.md
- [x] Old central runbooks deleted
- [x] SECRETS.md files are gitignored

## Test Plan

### Manual Test

1. Verify each host has:
   - `hosts/<hostname>/docs/RUNBOOK.md` - operational procedures
   - `hosts/<hostname>/secrets/SECRETS.md` - credentials

2. Verify runbooks don't contain secrets:
   - No passwords in plain text
   - No API tokens
   - References point to SECRETS.md

### Automated Test

```bash
# Verify runbooks exist
for host in hsb0 hsb1 csb0 csb1 hsb8 gpc0 imac0 imac-mba-work; do
  [ -f "hosts/$host/docs/RUNBOOK.md" ] && echo "✅ $host RUNBOOK" || echo "❌ $host RUNBOOK missing"
  [ -f "hosts/$host/secrets/SECRETS.md" ] && echo "✅ $host SECRETS" || echo "❌ $host SECRETS missing"
done

# Verify old central runbooks deleted
[ ! -f "docs/RUNBOOK-hsb0.md" ] && echo "✅ Old hsb0 deleted" || echo "❌ Old hsb0 still exists"
[ ! -f "docs/RUNBOOK-hsb1.md" ] && echo "✅ Old hsb1 deleted" || echo "❌ Old hsb1 still exists"

# Verify secrets files are gitignored
git ls-files hosts/*/secrets/SECRETS.md | wc -l
# Expected: 0 (all files ignored)
```

## Test Results

- Manual test: [x] Pass
- Automated test: [x] Pass
- Date verified: 2025-12-01

## Follow-up

- See `2025-12-01-populate-secrets-documentation.md` for completing credential documentation
