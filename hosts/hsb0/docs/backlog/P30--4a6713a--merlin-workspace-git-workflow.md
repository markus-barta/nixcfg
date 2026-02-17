# Merlin workspace: version-control & git workflow

**Host**: hsb0
**Priority**: P30
**Status**: Backlog
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

- [ ] Add GitHub PAT secret to `secrets/secrets.nix` + `configuration.nix`
- [ ] Add PAT to docker-compose secrets mount
- [ ] Replace workspace dir in container with git clone of `oc-workspace-merlin`
  - Container path: `/home/node/.openclaw/workspace/`
  - Remote URL: `https://<PAT>@github.com/markus-barta/oc-workspace-merlin.git`
- [ ] Configure git identity in container:
  ```
  git config user.name "Merlin AI"
  git config user.email "merlin-ai-mba@users.noreply.github.com"
  ```
- [ ] Verify Merlin can `git add/commit/push`

### Phase 3: Operational commands

- [ ] Create `just` recipes or scripts for:
  - `merlin-update-workspace` — pull latest changes into container
  - `merlin-rebuild` — rebuild + restart container
- [ ] Ensure container startup handles git pull (or at least doesn't break if repo exists)
- [ ] Document workflow in OPENCLAW-RUNBOOK.md

### Phase 4: Local development setup

- [x] Clone repo to `~/Code/oc-workspace-merlin` on imac0
- [x] Create VS Code workspace file `nixcfg+merlin.code-workspace`
- [x] Set up direnv/GH_TOKEN for markus-barta (done via `~/Code/.envrc`)

### Phase 5: Documentation

- [ ] Update `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md` with workspace git workflow
- [ ] Document how Markus pushes changes Merlin picks up
- [ ] Document how Merlin pushes changes Markus can review

## Acceptance Criteria

- [ ] `oc-workspace-merlin` repo has clean `.gitignore`, no junk files tracked
- [ ] `@merlin-ai-mba` can push to the repo
- [ ] Merlin's container workspace is a git clone of the repo
- [ ] Merlin can commit and push workspace changes
- [ ] Markus can see Merlin's changes locally
- [ ] Markus can push changes that Merlin picks up
- [ ] `workbench/` exists for Merlin's generated/working files
- [ ] OPENCLAW-RUNBOOK.md updated with git workflow

## Notes

- Pattern mirrors Percy's setup (see P30--744b13a)
- Merlin runs 24/7 on hsb0 — container rebuild requires brief downtime
- GitHub PAT will be stored in agenix, mounted as docker secret (same pattern as Percy)
- Merlin's repo under `markus-barta` (personal infra), not `bytepoets-mba`
- Clone locally to `~/Code/oc-workspace-merlin` (not under BYTEPOETS/)
