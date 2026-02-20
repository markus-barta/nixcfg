# Merlin workspace: version-control & git workflow

**Host**: hsb0
**Priority**: P30
**Status**: Done
**Created**: 2026-02-17

---

## Problem

Merlin's OpenClaw workspace (`/home/node/.openclaw/workspace/` in container) is not version-controlled. Changes Merlin or Markus make are only on the live host — no history, no collaboration, no visibility. Mirrors the same problem Percy had (see `hosts/miniserver-bp/docs/backlog/P30--744b13a--percy-workspace-git-workflow.md`).

## Solution

Use `markus-barta/oc-workspace-merlin` (private GitHub repo) as the version-controlled workspace. Merlin pushes changes via `@merlin-ai-mba` GitHub account. Markus can see/edit via local clone + VS Code workspace.

## Prerequisites (manual, user-only)

- [x] Create GitHub account `@merlin-ai-mba`
- [x] Create GitHub repo `markus-barta/oc-workspace-merlin` (private)
- [x] Add `@merlin-ai-mba` as collaborator to `markus-barta/oc-workspace-merlin`
- [x] Accept collaborator invite as `@merlin-ai-mba`
- [x] Create classic PAT for `@merlin-ai-mba` (scopes: `repo`, `read:org`)
- [x] Store PAT in agenix: `hsb0-openclaw-github-pat.age`

## Implementation

### Phase 1: Repo setup & .gitignore

- [x] Initialize repo with `.gitignore` (node_modules/, .openclaw/, .DS_Store)
- [x] Create `workbench/` dir for generated/ephemeral files
- [x] Import workspace files from live hsb0 container
- [x] Initial commit + push

### Phase 2: Container integration

- [x] Add GitHub PAT secret to `secrets/secrets.nix` + `configuration.nix`
- [x] Add PAT to docker-compose secrets mount
- [x] Replace workspace dir in container with git clone of `oc-workspace-merlin`
  - Container path: `/home/node/.openclaw/workspace/`
  - Remote URL: `https://<PAT>@github.com/markus-barta/oc-workspace-merlin.git`
- [x] Configure git identity in container (done in entrypoint)
- [x] Deploy to hsb0 + rebuild container
- [x] Verify Merlin can `git add/commit/push`

### Phase 3: Git push strategy & awareness

Merlin decides when to commit+push (agent-native). Daily safety net ensures nothing is lost.

- [x] Add git awareness to Merlin's workspace (AGENTS.md or similar) telling him:
  - Workspace is git-tracked, he can/should commit meaningful changes
  - Use `git add/commit/push` when updating memory, skills, or config
  - `git config` already set (name: "Merlin AI", email: merlin-ai-mba noreply)
- [x] Add daily auto-push safety net to entrypoint (cron or OpenClaw cron):
  - If uncommitted changes exist, auto-commit+push with generic message
  - Runs at least once per day

### Phase 4: Just recipes

- [x] `merlin-pull-workspace` — `docker exec` git pull in container (Markus triggers when he pushed changes Merlin should pick up NOW)
- [x] `merlin-rebuild` — rebuild + restart container (after Dockerfile/docker-compose changes)

### Phase 5: Local development setup

- [x] Clone repo to `~/Code/oc-workspace-merlin` on imac0
- [x] Create VS Code workspace file `nixcfg+merlin.code-workspace`
- [x] Set up direnv/GH_TOKEN for markus-barta (done via `~/Code/.envrc`)

### Phase 6: Deploy & verify

- [x] Deploy to hsb0 (nixos-rebuild switch)
- [x] Rebuild Merlin container
- [x] Verify workspace cloned from git in container
- [x] Verify Merlin can `git add/commit/push`
- [x] Verify Markus can push changes + `merlin-pull-workspace` works

### Phase 7: Documentation

- [x] Update `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md` with workspace git workflow
- [x] Document the two flows:
  - **Merlin writes**: Merlin edits → commits → pushes → Markus sees via `git pull` locally
  - **Markus writes**: Markus edits → commits → pushes → `just merlin-pull-workspace` or wait for restart

## Workflow design

| Who                  | Action                                     | How                                        |
| -------------------- | ------------------------------------------ | ------------------------------------------ |
| **Merlin** writes    | Edits workspace files during conversations | In container, direct fs                    |
| **Merlin** publishes | Commits + pushes when meaningful           | `git add/commit/push` (he decides)         |
| **Safety net**       | Auto-push uncommitted changes              | Daily cron (at least 1x/day)               |
| **Markus** writes    | Edits workspace files locally              | `~/Code/oc-workspace-merlin` + VS Code     |
| **Markus** publishes | Commits + pushes to GitHub                 | Normal git workflow                        |
| **Merlin** receives  | Picks up Markus's changes                  | `just merlin-pull-workspace` or on restart |

## Acceptance Criteria

- [x] `oc-workspace-merlin` repo has clean `.gitignore`, no junk files tracked
- [x] `@merlin-ai-mba` can push to the repo
- [x] Merlin's container workspace is a git clone of the repo
- [x] Merlin can commit and push workspace changes (he decides when)
- [x] Daily safety net auto-pushes uncommitted changes
- [x] Markus can see Merlin's changes locally
- [x] Markus can push changes that Merlin picks up via `just merlin-pull-workspace`
- [x] `workbench/` exists for Merlin's generated/working files
- [x] OPENCLAW-RUNBOOK.md updated with git workflow

## Notes

- Pattern mirrors Percy's setup (see P30--744b13a)
- Merlin runs 24/7 on hsb0 — container rebuild requires brief downtime
- GitHub PAT stored in agenix, mounted as docker secret (same pattern as Percy)
- Merlin's repo under `markus-barta` (personal infra), not `bytepoets-mba`
- Clone locally to `~/Code/oc-workspace-merlin` (not under BYTEPOETS/)
- Config changes: agent makes config, Markus deploys, together we validate
