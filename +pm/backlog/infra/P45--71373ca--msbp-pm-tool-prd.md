# PRD: Lightweight Project Management Tool ("pm-tool")

**Created**: 2026-02-09
**Priority**: P4500 (Medium)
**Status**: Backlog

---

## Problem

BYTEPOETS needs a lightweight, self-hosted project management tool for tracking projects, tickets, and basic workflows. Commercial tools are overkill for the scale (~30 projects/year, 15 users, hundreds of issues/project).

---

## Product Overview

A minimal CRUD web application for project and issue tracking. Think "RedBan-lite" — projects with tickets, basic status workflows, nothing fancy.

### Stack

| Layer    | Choice                 | Rationale                                    |
| -------- | ---------------------- | -------------------------------------------- |
| Frontend | Vue 3 + Vite           | Lightweight, fast builds, good DX            |
| Backend  | Go (chi/echo)          | Tiny binary (~10MB RAM), seconds to compile  |
| Database | SQLite                 | Zero overhead, file-based, perfect for scale |
| Auth     | Session cookies        | Simple, swap to OIDC/ID Austria later        |
| Deploy   | Docker on msbp         | Single container, port 8888                  |
| Repo     | `markus-barta/pm-tool` | Separate from nixcfg                         |

### Hardware Constraints (msbp)

| Resource | Available          | Budget for pm-tool |
| -------- | ------------------ | ------------------ |
| CPU      | Core 2 Duo 2.53GHz | ~50% max           |
| RAM      | 8GB (6.3GB free)   | ~200MB max         |
| Disk     | 467GB ZFS free     | Minimal            |

### Scale

- <50 projects/year
- <50 users
- <300 issues/project
- Single-digit concurrent users

---

## Core Features (MVP)

### Projects

- Create/edit/archive project
- Fields: name, description, status (active/archived), created date

### Issues/Tickets

- Create/edit/close issues within a project
- Fields: title, description, status (open/in-progress/done/closed), priority (low/medium/high), assignee, created/updated date
- List view with filtering by status/priority

### Users & Auth

- Username/password login (session cookies)
- Basic roles: admin, member
- Future: OIDC / ID Austria integration point

### Dashboard

- List of active projects
- Recent activity

---

## Non-Goals (MVP)

- No real-time collaboration / websockets
- No file attachments
- No Gantt charts / time tracking
- No email notifications
- No mobile app
- No API for external integrations (yet)

---

## Future Considerations

- OIDC / ID Austria authentication
- REST API for integrations
- Markdown support in descriptions
- Activity log / audit trail

---

## Related

- P4550: msbp Docker infrastructure setup
- P4600: msbp pm-tool deployment pipeline
- P4650: pm-tool repo scaffolding
