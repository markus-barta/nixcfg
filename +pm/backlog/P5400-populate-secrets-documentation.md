# 2025-12-01 - Populate SECRETS.md Files with Credentials

## Description

Complete the SECRETS.md documentation for all hosts by filling in missing credentials. These files serve as emergency access documentation (gitignored) so that in case of emergency, all login information is available.

## Source

- Original: Runbook restructuring session (December 2025)
- Related: `2025-11-29-secrets-directory-restructure.md`

## Scope

Applies to: All hosts with SECRETS.md files

## Background

During the runbook restructuring, we:

1. Moved runbooks from `docs/` to `hosts/<hostname>/docs/RUNBOOK.md`
2. Created clean runbooks without secrets for cloud servers
3. Deprecated old runbooks with inline secrets
4. Created SECRETS.md templates for all hosts

The cloud servers (csb0, csb1) have complete credentials extracted from their deprecated runbooks. Home servers and workstations need credentials filled in.

## Current State

### ✅ Complete (all credentials documented)

- `hosts/csb0/secrets/SECRETS.md` - All services documented
- `hosts/csb1/secrets/SECRETS.md` - All services documented

### ⚠️ Templates (need credentials)

| Host              | Missing Credentials                                                                    |
| ----------------- | -------------------------------------------------------------------------------------- |
| **hsb0**          | AdGuard Home admin password (plain text of bcrypt hash)                                |
| **hsb1**          | Home Assistant, Node-RED, Mosquitto MQTT, Scrypted, Tapo cameras, Restic backup        |
| **hsb8**          | Default password needs changing after deployment, Docker service creds (when deployed) |
| **gpc0**          | Steam account (if needed), root password (if set)                                      |
| **imac0**         | macOS login (if desired), Apple ID reference, service accounts                         |
| **imac-mba-work** | Work service credentials (Jira, GitLab, etc.)                                          |

## Acceptance Criteria

- [ ] hsb0: AdGuard Home admin password documented
- [ ] hsb1: All Docker service credentials documented
  - [ ] Home Assistant admin credentials
  - [ ] Node-RED credentials (if auth enabled)
  - [ ] Mosquitto MQTT `smarthome` user password
  - [ ] Scrypted admin credentials
  - [ ] Tapo C210 camera credentials
  - [ ] Restic backup repository and password
- [ ] hsb8: Document password change requirement
- [ ] gpc0: Add relevant credentials (if any)
- [ ] imac0: Add relevant credentials (if any)
- [ ] imac-mba-work: Add work service credentials
- [ ] All 1Password entry references verified

## Test Plan

### Manual Test

1. For each host SECRETS.md:
   - Verify all services listed in RUNBOOK.md have corresponding credentials in SECRETS.md
   - Verify all credentials match 1Password entries (where referenced)
   - Verify no credentials are missing that would block emergency access

2. Emergency access simulation:
   - Using only SECRETS.md, verify you can access:
     - SSH to the host
     - All web UIs listed
     - All service credentials needed

### Automated Test

```bash
# Verify all SECRETS.md files exist
for host in hsb0 hsb1 csb0 csb1 hsb8 gpc0 imac0 imac-mba-work; do
  [ -f "hosts/$host/secrets/SECRETS.md" ] && echo "✅ $host" || echo "❌ $host missing"
done

# Verify files are gitignored (should return empty - files not tracked)
git ls-files hosts/*/secrets/SECRETS.md
# Expected: no output (all files ignored)
```

## Notes

- SECRETS.md files are gitignored via `hosts/*/secrets/` pattern
- Encrypted .age files are allowed via `!hosts/*/secrets/*.age`
- Long-term goal: Migrate credentials to agenix-encrypted files
- See `2025-11-29-secrets-directory-restructure.md` for broader secrets management plans

## Priority

**Medium** - Emergency access documentation is important but not blocking daily operations.

## Related Files

- `hosts/*/secrets/SECRETS.md` - Files to populate
- `hosts/*/docs/RUNBOOK.md` - Reference for which services need credentials
- `hosts/csb0/secrets/DEPRECATED-RUNBOOK.md` - Example of complete credentials (for cloud servers)
- `hosts/csb1/secrets/DEPRECATED-RUNBOOK.md` - Example of complete credentials (for cloud servers)
