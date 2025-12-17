# Project Management

Central hub for tracking work across the nixcfg repository.

---

## Priority System

Tasks use a **P-number** prefix for ordering:

```
P{number}-{name}.md
```

**Lower number = Higher priority**

| Range       | Priority    | Description                           |
| ----------- | ----------- | ------------------------------------- |
| P4000-P4999 | 🔴 Critical | System maintenance, keeping things up |
| P5000-P5999 | 🟡 Medium   | Infrastructure improvements           |
| P6000-P6999 | 🟢 Low      | Nice-to-have, do when time permits    |

### Ordering Within Priority

- Start at **X000** (e.g., P4000, P5000, P6000)
- New items: add/subtract 100 (P4100, P4200...)
- Insert between: use finer granularity (P4050 between P4000 and P4100)
- **Goal**: Never need to rename existing files when priorities change

### Priority Focus: System Uptime

**Main priority indicator: Keep systems up to date and running.**

| Priority | Examples                                              |
| -------- | ----------------------------------------------------- |
| 🔴 P4xxx | Watchtower auto-updates, crash prevention, monitoring |
| 🟡 P5xxx | Security (agenix), agent deployments, build speed     |
| 🟢 P6xxx | Cleanup, cosmetic fixes, declarative improvements     |

---

## Workflow

```
┌──────────┐                      ┌──────┐
│ Backlog  │─────────────────────▶│ Done │
└──────────┘                      └──────┘
      │
      ▼
┌───────────┐
│ Cancelled │
└───────────┘
```

| State         | Folder       | Description                                               |
| ------------- | ------------ | --------------------------------------------------------- |
| **Backlog**   | `backlog/`   | All tasks: ideas, planned work, in-progress items         |
| **Done**      | `done/`      | Verified complete, kept indefinitely as historical record |
| **Cancelled** | `cancelled/` | No longer relevant/needed, kept for reference             |

### Moving Tasks

- **Backlog → Done**: Task complete, verified working
- **Backlog → Cancelled**: No longer needed, add note explaining why

---

## When to Create a Task

| Situation                        | Create +pm task?                 |
| -------------------------------- | -------------------------------- |
| Quick fix, single file, <15 min  | ❌ No, just do it                |
| Change affects multiple files    | ✅ Yes                           |
| Change takes >30 min             | ✅ Yes                           |
| New feature or capability        | ✅ Yes                           |
| Refactoring or migration         | ✅ Yes                           |
| Bug fix with root cause analysis | ✅ Yes                           |
| Documentation-only change        | ❌ No (unless major restructure) |

**Rule of thumb**: If you need to track progress or might get interrupted, create a task.

---

## File Naming Convention

```
P{number}-{short-description}.md
```

Examples:

- `P4000-cloud-servers-watchtower.md`
- `P5100-hsb1-agenix-secrets.md`

**Note**: Date is tracked inside the file, not in the filename.

---

## Task Template

````markdown
# Task Title

**Created**: YYYY-MM-DD  
**Priority**: P{number} (Critical/Medium/Low)  
**Status**: Backlog  
**Depends on**: P{other} (optional)

---

## Problem

Brief explanation of what needs to be fixed or built.

---

## Solution

How we're going to solve it.

---

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

---

## Test Plan

### Manual Test

1. Step 1 to verify
2. Step 2 to verify

### Automated Test

```bash
# Commands to verify
```
````

---

## Related

- Depends on: P{number}
- Enables: P{number}

```

---

## Test Requirements

Every task should have tests defined:

| Test Type       | Description                              | Required    |
| --------------- | ---------------------------------------- | ----------- |
| **Manual Test** | Human verification steps in the task     | ✅ Yes      |
| **Automated**   | Script or commands that verify the change | Recommended |

### Testing Approaches

| Test Type     | How to Test                              |
| ------------- | ---------------------------------------- |
| **NixOS**     | `nixos-rebuild test`, host test scripts  |
| **macOS**     | `home-manager switch`, manual verify     |
| **Services**  | `systemctl status`, curl endpoints       |
| **Docker**    | `docker compose up -d`, logs check       |

---

## Related

- [Main README](../README.md) - Project overview
- [Tests](../tests/README.md) - Test infrastructure
- [NixFleet +pm](../../nixfleet/+pm/README.md) - Same system for NixFleet
```
