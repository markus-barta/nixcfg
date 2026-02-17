# Percy workspace: version-control & git workflow

**Host**: miniserver-bp
**Priority**: P30
**Status**: Backlog
**Created**: 2026-02-17

---

## Problem

Percy's OpenClaw workspace (`/home/node/.openclaw/workspace/` in container) is not version-controlled. Changes Percy or Markus make are only on the live host — no history, no collaboration, no visibility. Files like `rechnung-data.json` and `AI-Budget-2026.csv` mix with tracked workspace docs.

## Solution

Use `bytepoets-mba/oc-workspace-percy` (private GitHub repo) as the version-controlled workspace. Percy pushes changes via `@bytepoets-percyai` GitHub account. Markus can see/edit via local clone + VS Code workspace (`nixcfg+percy.code-workspace`).

## Decisions Made

| Topic                                | Decision                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------- |
| Repo                                 | `bytepoets-mba/oc-workspace-percy` (private, created)                        |
| Percy GitHub                         | `@bytepoets-percyai` — add as collaborator                                   |
| Scratch folder                       | `workbench/` — gitignored, for generated/ephemeral files                     |
| `node_modules/`                      | Gitignored                                                                   |
| `.openclaw/`                         | Gitignored                                                                   |
| `.DS_Store`                          | Gitignored                                                                   |
| `package.json` / `package-lock.json` | Tracked (skill dependencies)                                                 |
| `rechnung-data.json`                 | Move to `workbench/` (tracked)                                               |
| `AI-Budget-2026.csv`                 | Move to `workbench/` (tracked)                                               |
| `extract-pdf.js`                     | Move to `workbench/` (tracked, but ask Percy if it's a utility or ephemeral) |
| `HEARTBEAT.md`                       | Tracked (want change history)                                                |
| VS Code workspace                    | `nixcfg+percy.code-workspace` (created, in nixcfg)                           |

## Implementation

### Phase 1: Repo setup & .gitignore

- [ ] Add `@bytepoets-percyai` as collaborator to `bytepoets-mba/oc-workspace-percy`
- [ ] Create `.gitignore` in repo:
  ```
  node_modules/
  .openclaw/
  .DS_Store
  ```
- [ ] Create `workbench/` dir
- [ ] Move `rechnung-data.json`, `AI-Budget-2026.csv`, `extract-pdf.js` to `workbench/`
- [ ] Ask Percy about `extract-pdf.js` — keep in `workbench/` or move back to root
- [ ] Initial commit with all tracked files
- [ ] Push to remote

### Phase 2: Container integration

- [ ] Replace workspace dir in container with git clone of `oc-workspace-percy`
  - Container path: `/home/node/.openclaw/workspace/`
  - Must use Percy's PAT for auth
  - Remote URL: `https://<PAT>@github.com/bytepoets-mba/oc-workspace-percy.git`
- [ ] Configure git identity in container:
  ```
  git config user.name "Percy AI"
  git config user.email "percy.ai@bytepoets.com"
  ```
- [ ] Verify Percy can `git add/commit/push`

### Phase 3: Operational commands

- [ ] Create `just` recipes or scripts for:
  - `percy-update-workspace` — pull latest changes into container
  - `percy-rebuild` — rebuild + restart container
- [ ] Ensure container startup handles git pull (or at least doesn't break if repo exists)
- [ ] Document workflow in OPENCLAW-RUNBOOK.md

### Phase 4: Documentation

- [ ] Update `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md` with workspace git workflow
- [ ] Document how Markus pushes changes Percy picks up
- [ ] Document how Percy pushes changes Markus can review

## Acceptance Criteria

- [ ] `oc-workspace-percy` repo has clean `.gitignore`, no junk files tracked
- [ ] `@bytepoets-percyai` can push to the repo
- [ ] Percy's container workspace is a git clone of the repo
- [ ] Percy can commit and push workspace changes
- [ ] Markus can see Percy's changes in VS Code via `nixcfg+percy.code-workspace`
- [ ] Markus can push changes that Percy picks up
- [ ] `workbench/` exists for Percy's generated/working files, tracked in git
- [ ] OPENCLAW-RUNBOOK.md updated with git workflow

## Notes

- Percy runs 24/7 — container rebuild requires brief downtime
- Cold-copy opportunity needed to ask Percy about `extract-pdf.js`
- GitHub PAT already in agenix (`miniserver-bp-github-pat.age`) and docker-compose
- `gh` CLI already added to container Dockerfile
