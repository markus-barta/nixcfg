# Project Management

Central hub for tracking work across the nixcfg repository.

## Workflow States

```
┌──────────┐    ┌───────┐    ┌────────┐    ┌────────┐    ┌──────┐
│ Backlog  │───▶│ Ready │───▶│ Active │───▶│ Review │───▶│ Done │
└──────────┘    └───────┘    └────────┘    └────────┘    └──────┘
                    │            │             │
                    ▼            ▼             ▼
               ┌───────────────────────────────────┐
               │           Cancelled               │
               └───────────────────────────────────┘
```

| State         | Folder       | Description                                                                 |
| ------------- | ------------ | --------------------------------------------------------------------------- |
| **Backlog**   | `backlog/`   | Raw ideas and tasks captured, not yet refined                               |
| **Ready**     | `ready/`     | Refined with clear acceptance criteria and test plan, ready to be picked up |
| **Active**    | `active/`    | Currently being worked on                                                   |
| **Review**    | `review/`    | Work complete, pending test verification (manual + automated)               |
| **Done**      | `done/`      | Verified complete, tests passed, kept indefinitely as historical record     |
| **Cancelled** | `cancelled/` | No longer relevant/needed, kept for reference                               |

## Moving Tasks Through States

### Backlog → Ready

- Add clear **Acceptance Criteria**
- Define **Manual Test** steps
- Define **Automated Test** (script reference or inline)
- Move file to `ready/`

### Ready → Active

- Pick up the task
- Move file to `active/`

### Active → Review

- Complete the implementation
- Move file to `review/`
- Run tests

### Review → Done

- **Both manual and automated tests must pass**
- Document test results in the task file
- Move file to `done/`

### Any State → Cancelled

- Add note explaining why cancelled
- Move file to `cancelled/`

## Test Requirements

Every task must have tests defined before moving to `ready/`:

| Test Type          | Description                                     | Required |
| ------------------ | ----------------------------------------------- | -------- |
| **Manual Test**    | Human verification steps documented in the task | ✅ Yes   |
| **Automated Test** | Script that can verify the change               | ✅ Yes   |

### Where Tests Live

| Test Type              | Location                                 | Purpose                                           |
| ---------------------- | ---------------------------------------- | ------------------------------------------------- |
| **Host-specific**      | `hosts/<hostname>/tests/`                | Ongoing functionality tests (DNS, services, etc.) |
| **General/structural** | `tests/`                                 | Repository structure, cross-cutting concerns      |
| **Task-specific**      | Inline in task file or referenced script | One-time verification                             |

See [tests/README.md](../tests/README.md) for test writing guidelines.

## File Naming Convention

Files are date-prefixed: `YYYY-MM-DD-short-description.md`

Example: `2025-12-01-migrate-csb0-to-hokage.md`

## Task Template

````markdown
# YYYY-MM-DD - Task Title

## Description

Brief explanation of what needs to be done.

## Source

- Original: [path to source file where TODO was found]
- Status at extraction: [original status if applicable]

## Scope

Applies to: [host/module/area affected]

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Test Plan

### Manual Test

1. Step 1 to verify
2. Step 2 to verify
3. Expected result

### Automated Test

```bash
# Reference to test script or inline commands
bash tests/T##-test-name.sh
# Or inline:
# grep -r "pattern" . && echo "PASS" || echo "FAIL"
```
````

## Notes

- Relevant context, links, or references

## Test Results

_Completed when moving to Done:_

- Manual test: [ ] Pass / [ ] Fail
- Automated test: [ ] Pass / [ ] Fail
- Date verified: YYYY-MM-DD

```

## Current Summary

### Done (4 items)

- `2025-12-01-runbook-restructuring.md` — Runbook restructuring complete ✅
- `2025-11-26-hsb1-nixos-migration.md` — hsb1 NixOS migration complete ✅
- `2025-12-01-cicd-hostname-fix.md` — CI/CD hostname fix complete ✅
- `2025-12-01-cleanup-docs-old-hostnames.md` — Main docs hostname cleanup ✅

### Cancelled (1 item)

- `2025-11-29-mkserverhost-refactor.md` — mkServerHost no longer used

### Backlog (11 items)

**Host Migrations**
- `2025-11-29-csb0-hokage-migration.md` — csb0 external hokage
- `2025-12-01-hsb1-agenix-secrets.md` — hsb1 agenix secrets migration
- `2025-12-01-hsb1-docker-restructure.md` — hsb1 docker/scripts to repo

**Infrastructure**
- `2025-11-29-netcup-monitor-declarative.md` — Declarative netcup monitoring
- `2025-11-29-secrets-directory-restructure.md` — Cleanup legacy secrets & host keys

**Documentation**
- `2025-12-01-populate-secrets-documentation.md` — Fill in SECRETS.md credentials

**Development**
- `2025-12-01-catppuccin-follows-cleanup.md` — Disable catppuccin theming
- `2025-12-01-imac0-secrets-management.md` — Age-based secrets for imac0
- `2025-12-01-cicd-pipeline-fixes.md` — CI/CD optional improvements
- `2025-12-01-pingt-standalone-package.md` — Standalone pingt package
- `2025-12-01-hsb8-home-assistant.md` — Home Assistant on hsb8
```
