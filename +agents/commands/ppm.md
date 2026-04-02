# PPM Mode — Read-Only Project Overview

You are in **PPM mode**. This is a read-only session focused on project planning and oversight using PPM.

## Constraints

- **DO NOT** modify any local files, configs, or code unless the user explicitly says "this is an exception"
- **DO NOT** build, deploy, or provision anything
- **DO** read local files for context (docs, nix configs, etc.)
- **DO** interact with PPM freely: query, create tickets, update statuses, add comments
- **DO** manage time entries: start/stop timers, log flat hours

## PPM Context

- **Base URL**: `https://pm.barta.cm`
- **Auth**: `Authorization: Bearer $PPMAPIKEY`

### Projects

| Project               | ID  | Key   | Scope                                                                       |
| --------------------- | --- | ----- | --------------------------------------------------------------------------- |
| NixCfg Infrastructure | 1   | NIX   | This repo — all NixOS/macOS hosts, agents (Merlin, Nimue, Percy), smarthome |
| DSC Infrastructure    | 2   | DSC26 | DSC-AI repo — dsc0, Ocean, Adi, FleetCom                                    |

**Default project for this repo**: NIX (project ID: 1)

When creating/querying issues, use project ID 1 unless the user explicitly references DSC26.

## Key API Endpoints

| Action                 | Method | Endpoint                                                                                                      |
| ---------------------- | ------ | ------------------------------------------------------------------------------------------------------------- |
| List project issues    | GET    | `/api/projects/{project_id}/issues`                                                                           |
| Issue tree (hierarchy) | GET    | `/api/projects/{project_id}/issues/tree`                                                                      |
| Single issue           | GET    | `/api/issues/{id}`                                                                                            |
| Create issue           | POST   | `/api/projects/{project_id}/issues`                                                                           |
| Update issue           | PUT    | `/api/issues/{id}`                                                                                            |
| Delete issue           | DELETE | `/api/issues/{id}`                                                                                            |
| Issue children         | GET    | `/api/issues/{id}/children`                                                                                   |
| Issue comments         | GET    | `/api/issues/{id}/comments`                                                                                   |
| Add comment            | POST   | `/api/issues/{id}/comments` body: `{body}`                                                                    |
| Issue history          | GET    | `/api/issues/{id}/history`                                                                                    |
| Search (cross-project) | GET    | `/api/search?q=...`                                                                                           |
| Recent issues          | GET    | `/api/issues/recent`                                                                                          |
| Time entries           | GET    | `/api/issues/{id}/time-entries`                                                                               |
| Create time entry      | POST   | `/api/issues/{id}/time-entries` body: `{"user_id": 2}` or `{"user_id": 2, "override": 1.5, "comment": "..."}` |
| Update time entry      | PUT    | `/api/time-entries/{id}` body: `{"stopped_at": "ISO8601"}`                                                    |

### Filtering (query params, comma-separated)

`?status=new,in-progress` `?priority=high` `?type=epic,ticket` `?assignee_id=1,unassigned` `?limit=50&offset=0`

### Issue Fields for Create/Update

```json
{
  "title": "...",
  "type": "ticket|epic|task",
  "status": "new|backlog|in-progress|qa|done|accepted|invoiced|cancelled",
  "priority": "low|medium|high",
  "description": "...",
  "acceptance_criteria": "...",
  "parent_id": null
}
```

## Time Tracking

- **mba user_id**: 2
- **Start timer**: `POST /api/issues/{id}/time-entries` with `{"user_id": 2}`
- **Stop timer**: `PUT /api/time-entries/{id}` with `{"stopped_at": "<ISO8601>"}`
- **Log flat hours**: `POST /api/issues/{id}/time-entries` with `{"user_id": 2, "override": 1.5, "comment": "description"}`
- Always check for running timers before starting a new one
- Stop timers when work is done

## Default Behavior

When the user invokes `/ppm` without further instructions, show a **project dashboard**:

1. Fetch all issues: `GET /api/projects/1/issues` (NIX) — and optionally `GET /api/projects/2/issues` (DSC26) for cross-project awareness
2. Present a summary grouped by epic:
   - Epic title and status
   - Count of child tickets by status (done / in-progress / new / backlog)
   - Any tickets without a parent epic
3. Highlight actionable items:
   - Tickets in `new` status (need triage)
   - Epics in `in-progress` with all children done (ready to close)
   - Any stale `in-progress` items
   - Running time entries

Format as a compact table the user can scan quickly.
