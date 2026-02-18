# Percy workspace: version-control & git workflow

**Host**: miniserver-bp
**Priority**: P30
**Status**: Backlog
**Created**: 2026-02-17

---

## Problem

Percy's OpenClaw workspace (`/home/node/.openclaw/workspace/` in container) is not version-controlled. Changes Percy or Markus make are only on the live host — no history, no collaboration, no visibility. Files like `rechnung-data.json` and `AI-Budget-2026.csv` mix with tracked workspace docs. Mirrors the same problem Merlin had (see `hosts/hsb0/docs/backlog/P30--4a6713a--merlin-workspace-git-workflow.md` - completed successfully on 2026-02-17).

## Solution

Use `bytepoets-mba/oc-workspace-percy` (private GitHub repo) as the version-controlled workspace. Percy pushes changes via `@bytepoets-percyai` GitHub account. Markus can see/edit via local clone + VSCodium workspace (`nixcfg+agents.code-workspace` or `nixcfg+percy.code-workspace`).

## Decisions Made

| Topic                                | Decision                                                                          |
| ------------------------------------ | --------------------------------------------------------------------------------- |
| Repo                                 | `bytepoets-mba/oc-workspace-percy` (private, created)                             |
| Percy GitHub                         | `@bytepoets-percyai` — add as collaborator                                        |
| Scratch folder                       | `workbench/` — **tracked in git**, for generated/working files                    |
| `node_modules/`                      | Gitignored                                                                        |
| `.openclaw/`                         | Gitignored                                                                        |
| `.DS_Store`                          | Gitignored                                                                        |
| `package.json` / `package-lock.json` | Tracked (skill dependencies)                                                      |
| `rechnung-data.json`                 | Move to `workbench/` (tracked)                                                    |
| `AI-Budget-2026.csv`                 | Move to `workbench/` (tracked)                                                    |
| `extract-pdf.js`                     | Move to `workbench/` (tracked, but ask Percy if it's a utility or ephemeral)      |
| `HEARTBEAT.md`                       | Tracked (want change history)                                                     |
| VS Code workspace                    | `nixcfg+percy.code-workspace` + combined `nixcfg+agents.code-workspace`           |
| Git push strategy                    | Percy decides when to push + daily auto-push safety net                           |
| Percy's git email                    | `percy.ai@bytepoets.com` → change to `bytepoets-percyai@users.noreply.github.com` |

## Prerequisites (manual, user-only)

- [x] Create GitHub account `@bytepoets-percyai`
- [x] Create GitHub repo `bytepoets-mba/oc-workspace-percy` (private)
- [ ] Add `@bytepoets-percyai` as collaborator to `bytepoets-mba/oc-workspace-percy`
- [ ] Accept collaborator invite as `@bytepoets-percyai`
- [ ] Verify classic PAT exists for `@bytepoets-percyai` (scopes: `repo`, `read:org`)
- [x] PAT already in agenix: `miniserver-bp-github-pat.age` (verify it's the right one)

## Implementation

### Phase 1: Repo setup & .gitignore

- [ ] Clone live workspace from miniserver-bp container to local machine
- [ ] Initialize repo with `.gitignore`:
  ```
  node_modules/
  .openclaw/
  .DS_Store
  ```
- [ ] Create `workbench/` dir for generated/working files
- [ ] Move `rechnung-data.json`, `AI-Budget-2026.csv`, `extract-pdf.js` to `workbench/`
- [ ] Import workspace files from live container (AGENTS.md, skills/, memory/, etc.)
- [ ] Initial commit + push

### Phase 2: Container integration

- [ ] Verify GitHub PAT secret in `secrets/secrets.nix` + `configuration.nix`
- [ ] Verify PAT mounted in docker-compose secrets
- [ ] Update docker-compose entrypoint to:
  - Clone workspace from `bytepoets-mba/oc-workspace-percy` on first boot
  - Pull latest on subsequent boots
  - Configure git identity: `Percy AI <bytepoets-percyai@users.noreply.github.com>`
  - Add daily auto-push background loop (safety net)
- [ ] Deploy to miniserver-bp + rebuild container
- [ ] Verify Percy can `git add/commit/push`

### Phase 3: Git push strategy & awareness

Percy decides when to commit+push (agent-native). Daily safety net ensures nothing is lost.

- [ ] Add git awareness to Percy's workspace (AGENTS.md) telling her:
  - Workspace is git-tracked, she can/should commit meaningful changes
  - Use `git add/commit/push` when updating memory, skills, or config
  - `git config` already set
- [ ] Daily auto-push already implemented in Phase 2 entrypoint

### Phase 4: Just recipes

- [ ] `percy-stop` — stop gateway (container stays, process stops)
- [ ] `percy-start` — start gateway
- [ ] `percy-pull-workspace` — pull latest changes into container (after Markus pushes)
- [ ] `percy-rebuild` — rebuild + restart container (after Dockerfile/docker-compose changes)
- [ ] `percy-status` — container status + recent logs
- [ ] All recipes work from imac0 (SSH) and locally on miniserver-bp

### Phase 5: Local development setup

- [x] VS Code workspace `nixcfg+percy.code-workspace` already exists
- [x] Combined workspace `nixcfg+agents.code-workspace` includes Percy
- [x] Clone repo to `~/Code/oc-workspace-percy` (done on imac0 + mba-imac-work)
- [x] Set up direnv/GH_TOKEN via `.envrc` in workspace (macOS Keychain: `gh-token-bytepoets-mba`)
- [x] Percy remote switched to SSH: `git@github-bp:bytepoets-mba/oc-workspace-percy.git`

### Phase 6: Deploy & verify

- [ ] Deploy to miniserver-bp (nixos-rebuild switch)
- [ ] Rebuild Percy container
- [ ] Verify workspace cloned from git in container
- [ ] Verify Percy can `git add/commit/push`
- [ ] Verify Markus can push changes + `just percy-pull-workspace` works

### Phase 7: Documentation

- [ ] Update `hosts/miniserver-bp/docs/OPENCLAW-RUNBOOK.md` with workspace git workflow
- [ ] Document the two flows:
  - **Percy writes**: Percy edits → commits → pushes → Markus sees via `git pull` locally
  - **Markus writes**: Markus edits → commits → pushes → `just percy-pull-workspace` or wait for restart
- [ ] Create IMPORTANT-UPDATE.md for Percy explaining the git workflow

## Workflow design

| Who                  | Action                                     | How                                       |
| -------------------- | ------------------------------------------ | ----------------------------------------- |
| **Percy** writes     | Edits workspace files during conversations | In container, direct fs                   |
| **Percy** publishes  | Commits + pushes when meaningful           | `git add/commit/push` (she decides)       |
| **Safety net**       | Auto-push uncommitted changes              | Daily cron (at least 1x/day)              |
| **Markus** writes    | Edits workspace files locally              | Local clone + VS Code                     |
| **Markus** publishes | Commits + pushes to GitHub                 | Normal git workflow                       |
| **Percy** receives   | Picks up Markus's changes                  | `just percy-pull-workspace` or on restart |

## Acceptance Criteria

- [ ] `oc-workspace-percy` repo has clean `.gitignore`, no junk files tracked
- [ ] `@bytepoets-percyai` can push to the repo
- [ ] Percy's container workspace is a git clone of the repo
- [ ] Percy can commit and push workspace changes (she decides when)
- [ ] Daily safety net auto-pushes uncommitted changes
- [ ] Markus can see Percy's changes locally
- [ ] Markus can push changes that Percy picks up via `just percy-pull-workspace`
- [ ] `workbench/` exists for Percy's generated/working files (tracked in git)
- [ ] OPENCLAW-RUNBOOK.md updated with git workflow

## Lessons learned from Merlin implementation

**What worked well:**

- Git clone on container startup (not manual seed)
- Daily auto-push as background process in entrypoint (`sleep 86400` loop)
- AGENTS.md file explaining git workflow to the AI
- Just recipes that work from both local and remote (via `_msbp-run` helper)
- GitHub PAT stored in agenix, mounted as docker secret
- Git identity configured in entrypoint (both on clone AND pull paths)
- workbench/ directory tracked in git (not gitignored)

**Specific implementation details to replicate:**

```yaml
# docker-compose entrypoint pattern:
command:
  - |
    export GITHUB_PAT=$$(cat /run/secrets/github-pat)

    # Initialize workspace
    WORKSPACE_DIR=/home/node/.openclaw/workspace
    if [ ! -d "$$WORKSPACE_DIR/.git" ]; then
      echo "Cloning workspace from GitHub..."
      rm -rf "$$WORKSPACE_DIR"
      git clone https://$$GITHUB_PAT@github.com/bytepoets-mba/oc-workspace-percy.git "$$WORKSPACE_DIR"
      cd "$$WORKSPACE_DIR"
      git config user.name "Percy AI"
      git config user.email "bytepoets-percyai@users.noreply.github.com"
    else
      echo "Workspace already cloned, pulling latest..."
      cd "$$WORKSPACE_DIR"
      git config user.name "Percy AI"
      git config user.email "bytepoets-percyai@users.noreply.github.com"
      git pull --ff-only || echo "Pull failed or conflicts, continuing..."
    fi

    # Daily auto-push safety net
    (while true; do
      sleep 86400
      cd "$$WORKSPACE_DIR"
      if [ -n "$$(git status --porcelain)" ]; then
        echo "[auto-push] Uncommitted workspace changes detected, pushing..."
        git add -A
        git commit -m "auto: daily workspace sync"
        git push || echo "[auto-push] Push failed, will retry next cycle"
      fi
    done) &

    exec openclaw gateway --port <PORT>
```

**Just recipes pattern:**

```just
[private]
_msbp-run cmd:
    #!/usr/bin/env bash
    if [ "$(hostname -s)" = "miniserver-bp" ]; then
        bash -c "{{ cmd }}"
    else
        ssh mba@miniserver-bp.local "{{ cmd }}"
    fi

[group('percy')]
percy-stop:
    just _msbp-run "cd ~/Code/nixcfg/hosts/miniserver-bp/docker && docker compose stop openclaw-percaival"
```

## Notes

- Pattern mirrors Merlin's setup (P30--4a6713a - completed 2026-02-17)
- Percy runs 24/7 on miniserver-bp — container rebuild requires brief downtime
- GitHub PAT already in agenix (`miniserver-bp-github-pat.age`) — verify it's for `@bytepoets-percyai`
- `gh` CLI already in container Dockerfile
- Percy's repo under `bytepoets-mba` (BYTEPOETS org), not `markus-barta`
- Clone locally to appropriate location (BYTEPOETS context vs personal)
- Config changes: agent makes config, Markus deploys, together we validate
