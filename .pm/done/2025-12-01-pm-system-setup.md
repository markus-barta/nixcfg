# 2025-12-01 - PM System Setup and Migration

## Description

Establish the centralized project management system for nixcfg repository. Migrate all existing TODOs from scattered README files and BACKLOG.md files into the new `PM/` structure.

## Acceptance Criteria

- [x] Create PM/ folder structure (backlog/, ready/, active/, review/, done/, cancelled/)
- [x] Create PM/README.md with workflow documentation
- [x] Sweep all READMEs and documentation for TODOs
- [x] Create individual backlog items for each TODO
- [x] Update source files with links to new backlog items
- [x] Create cleanup/inconsistency items per area
- [x] Create tests/ folder with README and guidelines
- [x] Document test requirements (manual + automated for each task)
- [x] QA/testing process verification (to be validated with first task through review)

## Test Plan

### Manual Test

1. Verify all PM folders exist: `ls PM/` shows backlog/, ready/, active/, review/, done/, cancelled/
2. Verify tests/ folder exists with README
3. Verify PM/README.md documents the full workflow
4. Verify task template includes test plan section
5. Check that old BACKLOG.md files link to new PM items

### Automated Test

```bash
# Verify folder structure
cd /Users/markus/Code/nixcfg
for dir in .pm/backlog .pm/done .pm/cancelled tests; do
  [[ -d "$dir" ]] && echo "✓ $dir exists" || echo "✗ $dir missing"
done

# Verify READMEs exist
for readme in PM/README.md tests/README.md; do
  [[ -f "$readme" ]] && echo "✓ $readme exists" || echo "✗ $readme missing"
done
```

## Migration Summary (2025-12-01)

### Folder Structure

```
PM/
├── README.md           # Workflow documentation
├── backlog/            # Raw capture (13 items)
├── ready/              # Refined with acceptance criteria + test plan
├── active/             # In progress
├── review/             # Work done, running tests
├── done/               # Verified complete
└── cancelled/          # Kept for reference

tests/
└── README.md           # Test philosophy and guidelines
```

### Backlog Items Created

| Item                              | Source                                      |
| --------------------------------- | ------------------------------------------- |
| hsb1 Full Migration               | hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md      |
| csb0 Hokage Migration             | hosts/csb0/docs/MIGRATION-PLAN-HOKAGE.md    |
| Netcup Monitor - Make Declarative | hosts/hsb1/BACKLOG.md                       |
| hsb8 ww87 Deployment              | hosts/hsb8/docs/📋 BACKLOG.md               |
| Secrets Directory Restructure     | secrets/📋 BACKLOG.md                       |
| Catppuccin Follows Cleanup        | modules/shared/README.md                    |
| imac0 Secrets Management          | hosts/imac0/docs/todo-secrets-management.md |
| CI/CD Pipeline Fixes              | docs/CI-CD-PIPELINE.md                      |
| pingt Standalone Package          | Memory (uzumaki backlog)                    |
| mkServerHost Refactor             | hosts/hsb8/docs/📋 BACKLOG.md               |

### Cleanup Items Created

| Item                                | Area   |
| ----------------------------------- | ------ |
| Old Hostname References             | docs/  |
| Hosts Documentation Inconsistencies | hosts/ |

### Source Files Updated

- `hosts/hsb1/BACKLOG.md` → Links to PM items
- `hosts/hsb8/docs/📋 BACKLOG.md` → Links to PM items
- `secrets/📋 BACKLOG.md` → Links to PM items
- `modules/shared/README.md` → Link added
- `hosts/imac0/docs/todo-secrets-management.md` → Link added

## Notes

- Source: This task created as part of initial PM setup
- Test philosophy: Every task needs manual + automated tests
- Host-specific tests remain in `hosts/<hostname>/tests/`
- General/structural tests go in `tests/`
