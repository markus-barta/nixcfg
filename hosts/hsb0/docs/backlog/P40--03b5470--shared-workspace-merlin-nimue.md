# shared-workspace-merlin-nimue

**Host**: hsb0
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-22

---

## Problem

Merlin and Nimue have fully isolated workspaces. They have zero shared family context — Merlin knows
Markus, Nimue knows Mailina, neither knows the other's user or shared family/home knowledge. As usage
grows this becomes a real gap (duplicated onboarding, inconsistent knowledge, one agent unaware of
what the other has learned).

## Solution

A third git repo (`oc-workspace-shared`) acts as a shared knowledge base. Both agent workspaces get
a `shared` symlink pointing to a shared clone of this repo. Both agents can read and write freely —
flat structure, no subfolders. No merge conflicts by design — each agent exclusively writes to their
own `FROM-*.md` file. The shared repo gets its own clone, pull, and push cycle in the entrypoint.

**Design:**

```
/home/node/.openclaw/
├── workspace-merlin/          # markus-barta/oc-workspace-merlin
│   ├── shared -> /home/node/.openclaw/workspace-shared   (symlink)
│   ├── .gitignore             # includes "shared"
│   └── ...
├── workspace-nimue/           # markus-barta/oc-workspace-nimue
│   ├── shared -> /home/node/.openclaw/workspace-shared   (symlink)
│   ├── .gitignore             # includes "shared"
│   └── ...
└── workspace-shared/              # markus-barta/oc-workspace-shared (new repo)
    ├── KNOWLEDGEBASE.md           # Core family context: names, relationships, home, routines (Markus maintains)
    ├── KB.md -> KNOWLEDGEBASE.md  # Symlink — short alias for agent use in chats/prompts
    ├── FROM-MERLIN.md             # Merlin writes, Nimue reads
    └── FROM-NIMUE.md              # Nimue writes, Merlin reads
```

Flat structure — no subfolders. No merge conflicts by design: each agent exclusively owns their `FROM-*.md`.
`KB.md` is a symlink inside the shared repo itself — short alias for agent use in chats/prompts.

## Implementation

### Phase 1: Create shared repo (Human — requires GitHub)

- [ ] **1.1** Create `markus-barta/oc-workspace-shared` (private repo) on GitHub
- [ ] **1.2** Initialize with:
  - `KNOWLEDGEBASE.md` — seed with: Markus + Mailina (married), Maurice (son), home in Graz Austria,
    home automation setup, shared routines, preferences
  - `KB.md` — symlink to `KNOWLEDGEBASE.md` (`ln -s KNOWLEDGEBASE.md KB.md`)
  - `FROM-MERLIN.md` — stub: "# From Merlin"
  - `FROM-NIMUE.md` — stub: "# From Nimue"
- [ ] **1.3** Grant read/write access to both agent GitHub accounts (`merlin-ai-mba`, `nimue-ai-mai`)
      — or use Markus' PAT via `GITHUB_PAT_MERLIN` (already in container, see Notes)

### Phase 2: nixcfg changes (AI can do — propose + get OK)

- [ ] **2.1** Add shared workspace clone + symlinks to `entrypoint.sh`:
  - Clone/pull `oc-workspace-shared` to `/home/node/.openclaw/workspace-shared/`
  - Create symlinks: `ln -sfn ../workspace-shared /home/node/.openclaw/workspace-merlin/shared`
    and same for Nimue
  - Add **per-agent** nightly sync (cron, NOT a background loop) for the shared repo:
    - **23:30:00** — Merlin: `git pull` → commit `FROM-MERLIN.md` → `git push` (as `merlin-ai-mba`)
    - **23:30:30** — Nimue: `git pull` → commit `FROM-NIMUE.md` → `git push` (as `nimue-ai-mai`)
    - Pull-before-push ensures each agent gets the other's latest before committing their own
    - 30s stagger eliminates push race between the two agents
    - `KNOWLEDGEBASE.md` is never touched by agents — Markus pushes manually
  - Use `GITHUB_PAT_MERLIN` / `GITHUB_PAT_NIMUE` respectively for push auth

- [ ] **2.2** Add `shared` to `.gitignore` in both agent workspace repos
      (`oc-workspace-merlin`, `oc-workspace-nimue`) — prevents git tracking the symlink

- [ ] **2.3** Add shared workspace dir to Dockerfile mkdir block:

  ```dockerfile
  /home/node/.openclaw/workspace-shared \
  ```

- [ ] **2.4** (Optional) Create dedicated `hsb0-shared-github-pat` agenix secret if Merlin's PAT
      should not have write access to the shared repo. Otherwise reuse `GITHUB_PAT_MERLIN`.

### Phase 3: Seed content (Human + AI)

- [ ] **3.1** Populate `KNOWLEDGEBASE.md` with real family context (AI drafts, Markus reviews)
- [ ] **3.2** Update both agent `AGENTS.md` files in their workspace repos:
  - "Your workspace contains a `shared/` directory — shared knowledge base with Merlin/Nimue.
    Read `shared/KB.md` (or `shared/KNOWLEDGEBASE.md`) for family context.
    Write to `shared/FROM-MERLIN.md` / `shared/FROM-NIMUE.md` when you learn something
    the other agent should know."

### Phase 4: Verify

- [ ] **4.1** Container boots, shared repo cloned, symlinks present in both workspaces
- [ ] **4.2** `docker exec openclaw-gateway ls workspace-merlin/shared/` shows shared files
- [ ] **4.3** `docker exec openclaw-gateway ls workspace-nimue/shared/` shows same files
- [ ] **4.4** Merlin can answer basic question about Mailina (reads `shared/KB.md` via symlink)
- [ ] **4.5** Nimue can answer basic question about Markus (reads `shared/KB.md` via symlink)
- [ ] **4.6** At 23:30 Merlin pulls shared, commits `FROM-MERLIN.md`, pushes as `merlin-ai-mba`
- [ ] **4.7** At 23:30:30 Nimue pulls shared (gets Merlin's push), commits `FROM-NIMUE.md`, pushes as `nimue-ai-mai`
- [ ] **4.8** Both agents have each other's latest knowledge by 23:31 every night
- [ ] **4.9** `KNOWLEDGEBASE.md` is NOT committed by agents (Markus-only)

### Phase 5: Documentation updates (AI can do)

- [ ] **5.1** Update `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`:
  - Add "Shared Workspace" section: purpose, repo, symlink paths, push behavior
  - Add `workspace-shared` row to Files Reference table
- [ ] **5.2** Update both agent `AGENTS.md` files in workspace repos (see Phase 3.2)

## Acceptance Criteria

- [ ] `markus-barta/oc-workspace-shared` exists with `KNOWLEDGEBASE.md`, `KB.md` (symlink), `FROM-MERLIN.md`, `FROM-NIMUE.md`
- [ ] Both agent workspaces have a working `shared/` symlink pointing to the shared clone
- [ ] `shared` is in `.gitignore` of both agent workspace repos
- [ ] Both agents can read `KNOWLEDGEBASE.md` (via `KB.md` alias) and answer basic cross-family questions
- [ ] Nightly sync at 23:30 — pull-then-push, Merlin first, Nimue 30s later
- [ ] Both agents have mutual knowledge by 23:31 every night
- [ ] `KNOWLEDGEBASE.md` never committed by agents
- [ ] OPENCLAW-RUNBOOK.md updated
- [ ] Both agent `AGENTS.md` files reference the shared workspace

## Notes

- **PAT for shared repo**: each agent uses their own PAT for push (`GITHUB_PAT_MERLIN` /
  `GITHUB_PAT_NIMUE`) — both already in container, just need access granted to `oc-workspace-shared`
  on GitHub. Clean audit trail: commits show correct author per agent. No new secrets needed.
- **Nightly sync at 23:30**: pull-then-push, Merlin at :00, Nimue at :30s — both agents have
  each other's latest by 23:31. Git history clearly shows who wrote what and when.
  No separate morning pull needed — the pull-before-push covers it.
- **Merge conflicts**: impossible by design — each agent exclusively writes to their own `FROM-*.md`.
  `KNOWLEDGEBASE.md` is maintained by Markus only, not written by agents.
- **Symlink + git**: git records the symlink as a file (the target path string), not the target
  content. `shared` in `.gitignore` keeps agent workspace repos clean.
- **OpenClaw file reading**: OpenClaw walks the workspace tree and follows symlinks —
  `shared/KB.md` and `shared/FROM-*.md` will be visible to each agent as workspace context automatically.
- **Future**: if OpenClaw adds native multi-workspace support, symlinks can be replaced cleanly.
