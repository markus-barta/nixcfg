# Project Management

Central hub for tracking work across the nixcfg repository.

## Workflow (Simple)

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

## File Naming Convention

Files are date-prefixed: `YYYY-MM-DD-short-description.md`

Example: `2025-12-01-migrate-csb0-to-hokage.md`

## Task Template

```markdown
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

## Notes

- Relevant context, links, or references
```

---

## Alternative: Full Kanban Workflow

For larger projects or teams, a more structured workflow may be useful:

```
┌──────────┐    ┌───────┐    ┌────────┐    ┌────────┐    ┌──────┐
│ Backlog  │───▶│ Ready │───▶│ Active │───▶│ Review │───▶│ Done │
└──────────┘    └───────┘    └────────┘    └────────┘    └──────┘
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
