# Project Management

Central hub for tracking work across the nixcfg repository.

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

| Situation                        | Create .pm task?                 |
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

Files are date-prefixed: `YYYY-MM-DD-short-description.md`

Example: `2025-12-01-migrate-csb0-to-hokage.md`

---

## Task Template

````markdown
# YYYY-MM-DD - Task Title

## Status: BACKLOG | DONE | CANCELLED

## Description

Brief explanation of what needs to be done.

## Source

- Original: [path to source file where TODO was found]

## Scope

Applies to: [host/module/area affected]

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Test Plan

### Manual Test

1. Step 1 to verify
2. Step 2 to verify
3. Expected result

### Automated Test

```bash
# Reference to test script or inline commands
bash hosts/<hostname>/tests/T##-test-name.sh
```
````

## Notes

- Relevant context, links, or references

```

---

## Test Requirements

Every task should have tests defined:

| Test Type          | Description                                     | Required |
| ------------------ | ----------------------------------------------- | -------- |
| **Manual Test**    | Human verification steps documented in the task | ✅ Yes   |
| **Automated Test** | Script that can verify the change               | Recommended |

### Where Tests Live

| Test Type              | Location                                 | Purpose                                           |
| ---------------------- | ---------------------------------------- | ------------------------------------------------- |
| **Host-specific**      | `hosts/<hostname>/tests/`                | Ongoing functionality tests (DNS, services, etc.) |
| **General/structural** | `tests/`                                 | Repository structure, cross-cutting concerns      |
| **Task-specific**      | Inline in task file or referenced script | One-time verification                             |

See [tests/README.md](../tests/README.md) for test writing guidelines.

---

## Alternative: Full Kanban Workflow

For larger projects or teams, a more structured workflow may be useful:

```

┌──────────┐ ┌───────┐ ┌────────┐ ┌────────┐ ┌──────┐
│ Backlog │───▶│ Ready │───▶│ Active │───▶│ Review │───▶│ Done │
└──────────┘ └───────┘ └────────┘ └────────┘ └──────┘

```

| State       | Description                                                   |
| ----------- | ------------------------------------------------------------- |
| **Backlog** | Raw ideas and tasks captured, not yet refined                 |
| **Ready**   | Refined with clear acceptance criteria, ready to be picked up |
| **Active**  | Currently being worked on (limit: 1-2 tasks)                  |
| **Review**  | Work complete, pending test verification                      |
| **Done**    | Verified complete                                             |

This approach is useful when:

- Multiple people work on the same codebase
- Tasks require formal review before completion
- You want explicit WIP limits
- Formal test plans are needed before starting work

For this personal nixcfg repo, the simple 3-state workflow is sufficient.
```
