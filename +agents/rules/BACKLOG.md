# Backlog Item Creation Guide

**For AI Agents**: This document explains how to properly create backlog items in nixcfg.

---

## Critical Rules

1. **ALWAYS use the script** - Never manually create backlog files
2. **Host-specific items go to host backlogs** - Not infrastructure backlog
3. **Use the provided template** - Script auto-generates structure
4. **Check before creating** - Verify item doesn't already exist

---

## Quick Reference

### Infrastructure-Wide Item

```bash
./scripts/create-backlog-item.sh P50 fix-bug-description
```

Creates: `+pm/backlog/P50.abc1234.fix-bug-description.md`

### Host-Specific Item

```bash
./scripts/create-backlog-item.sh P30 audit-docker --host hsb0
```

Creates: `hosts/hsb0/docs/backlog/P30.def5678.audit-docker.md`

---

## Decision Tree: Where Does This Item Go?

```
Does this task affect ONLY ONE host?
├─ YES → Use --host flag → hosts/<host>/docs/backlog/
└─ NO  → Default location → +pm/backlog/

Examples:
- "Fix csb0 Docker config" → --host csb0
- "Add monitoring to all hosts" → infrastructure (+pm/backlog/)
- "Update hsb1 secrets" → --host hsb1
- "Improve OpenClaw skill" → infrastructure (+pm/backlog/)
```

---

## Priority Selection

| Priority    | When to Use                             | Examples                            |
| ----------- | --------------------------------------- | ----------------------------------- |
| **A00-E99** | System down, security breach, data loss | Service crashed, exposed secrets    |
| **F00-O99** | Important but not critical              | Breaking changes, migrations        |
| **P00-P99** | Standard work (DEFAULT)                 | Features, improvements, refactoring |
| **Q00-V99** | Nice-to-have                            | Cleanup, cosmetic fixes             |
| **W00-Z99** | Future ideas                            | Research, someday/maybe             |

**Default**: Use **P50** when unsure.

**Sub-priority (00-99)**:

- Lower number = higher priority within letter
- P30 is higher priority than P50
- P50 is higher priority than P70

---

## Script Usage

### Basic Syntax

```bash
./scripts/create-backlog-item.sh [PRIORITY] [DESCRIPTION] [OPTIONS]
```

### Parameters

| Parameter   | Required | Format     | Default     | Example                 |
| ----------- | -------- | ---------- | ----------- | ----------------------- |
| PRIORITY    | No       | LNN        | P50         | A10, P30, Z99           |
| DESCRIPTION | No       | kebab-case | timestamp   | fix-bug, audit-docker   |
| --host      | No       | hostname   | -           | hsb0, csb1, imac0       |
| --dir       | No       | path       | +pm/backlog | hosts/hsb0/docs/backlog |

### Examples

```bash
# Quick infrastructure item (uses defaults)
./scripts/create-backlog-item.sh P50 implement-feature

# Critical host-specific issue
./scripts/create-backlog-item.sh A10 fix-crash --host csb0

# Low priority cleanup
./scripts/create-backlog-item.sh V80 cleanup-old-files --host hsb1

# With explicit directory
./scripts/create-backlog-item.sh P30 task --dir hosts/hsb0/docs/backlog

# Let script generate description (uses timestamp)
./scripts/create-backlog-item.sh P50
```

---

## After Creating the Item

The script outputs the filename. **Next steps**:

1. **Edit the file** to fill in template sections:
   - Problem: What needs fixing/building (1-3 sentences)
   - Solution: How you'll solve it (2-5 sentences)
   - Implementation: Actionable tasks (checkboxes)
   - Acceptance Criteria: Testable conditions
   - Notes: Dependencies, risks, references

2. **Keep it concise** - No excessive prose

3. **Make it actionable** - Clear checkboxes, specific tasks

4. **Make it testable** - Clear acceptance criteria

---

## Template Structure

Script auto-generates this template:

```markdown
# description

**Host**: hostname (if --host used)
**Priority**: LNN
**Status**: Backlog
**Created**: YYYY-MM-DD

---

## Problem

[What needs to be fixed or built]

## Solution

[How we're going to solve it]

## Implementation

- [ ] Task 1
- [ ] Task 2
- [ ] Documentation update
- [ ] Test

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Tests pass

## Notes

[Optional: Dependencies, risks, references]
```

---

## Common Patterns

### Bug Fix

```bash
./scripts/create-backlog-item.sh P40 fix-service-crash --host csb0
```

Template focus:

- **Problem**: Describe the bug and impact
- **Solution**: Root cause and fix approach
- **Implementation**: Code changes, testing
- **Notes**: How to reproduce, related issues

### New Feature

```bash
./scripts/create-backlog-item.sh P50 add-monitoring
```

Template focus:

- **Problem**: What capability is missing
- **Solution**: Design overview
- **Implementation**: Phased approach
- **Acceptance**: Feature works, documented

### Refactoring

```bash
./scripts/create-backlog-item.sh P60 simplify-config --host hsb1
```

Template focus:

- **Problem**: Why current approach is problematic
- **Solution**: Cleaner approach
- **Implementation**: Migration steps
- **Notes**: Rollback plan

---

## Host List Reference

Valid `--host` values:

| Host          | Type  | Location               |
| ------------- | ----- | ---------------------- |
| csb0          | NixOS | Cloud (Netcup)         |
| csb1          | NixOS | Cloud (Netcup)         |
| hsb0          | NixOS | Home LAN (crown jewel) |
| hsb1          | NixOS | Home LAN               |
| hsb2          | NixOS | Home LAN               |
| hsb8          | NixOS | Home LAN (parents)     |
| gpc0          | NixOS | Home LAN (gaming PC)   |
| imac0         | macOS | Home LAN (workstation) |
| mba-imac-work | macOS | BYTEPOETS office       |
| mba-mbp-work  | macOS | Portable (work)        |
| miniserver-bp | NixOS | BYTEPOETS office       |

---

## Troubleshooting

### "Error: +pm/ directory not found"

**Cause**: Running from wrong directory
**Fix**: Run from repository root (`~/Code/nixcfg`)

### "Invalid priority format"

**Cause**: Priority not in LNN format (e.g., used `P1000` instead of `P10`)
**Fix**: Use letter + 2 digits (P50, A10, Z99)

### "File already exists"

**Cause**: Hash collision (extremely rare)
**Fix**: Re-run script (generates new hash)

### "Which host should this be?"

**Guide**:

- Mentions one specific hostname in description? → Use --host
- Uses words like "all hosts", "fleet-wide", "infrastructure"? → Infrastructure
- Uncertain? → Infrastructure (easier to move later)

---

## Examples by Scenario

### Scenario: csb0 Docker cleanup needed

```bash
./scripts/create-backlog-item.sh P60 docker-cleanup --host csb0
```

**Why**:

- Affects only csb0 → host-specific
- Cleanup task → P60 (low priority)
- Clear description → docker-cleanup

### Scenario: Critical security fix on hsb1

```bash
./scripts/create-backlog-item.sh A05 patch-vulnerability --host hsb1
```

**Why**:

- Security issue → A (critical)
- Very urgent → 05 (low number)
- Single host → --host hsb1

### Scenario: New OpenClaw skill for all hosts

```bash
./scripts/create-backlog-item.sh P50 generic-ha-skill
```

**Why**:

- Generic feature → infrastructure
- Standard work → P50
- No --host (affects multiple/all)

### Scenario: Research new technology

```bash
./scripts/create-backlog-item.sh W90 research-k8s
```

**Why**:

- Future idea → W (backlog tier)
- Very low priority → 90
- Not host-specific → infrastructure

---

## Integration with Git

After creating and editing backlog item:

1. **Check git status**: `git status`
2. **Review changes**: `git diff`
3. **Commit**: Only when user asks
4. **Never commit secrets**: Scan for credentials before commit

---

## Related Documentation

- **Full details**: `+pm/README.md`
- **Agent rules**: `+agents/rules/AGENTS.md`
- **Infrastructure**: `docs/INFRASTRUCTURE.md`
- **Host docs**: `hosts/<hostname>/README.md`

---

## Quick Checklist

Before creating a backlog item:

- [ ] Running from repo root
- [ ] Decided: host-specific or infrastructure?
- [ ] Chosen appropriate priority (default P50)
- [ ] Description is kebab-case
- [ ] Used script (not manual file creation)

After creating:

- [ ] Filled in Problem section (concise)
- [ ] Filled in Solution section (clear approach)
- [ ] Added actionable Implementation tasks
- [ ] Defined testable Acceptance Criteria
- [ ] Reviewed for sensitive information
