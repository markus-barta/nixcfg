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
flat structure, no subfolders. No merge conflict risk in practice (they cover different domains:
Merlin covers Markus/tech/home-automation, Nimue covers Mailina/family/calendar). The shared repo
gets its own clone, pull, and push cycle in the entrypoint.

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
└── workspace-shared/          # markus-barta/oc-workspace-shared (new repo)
    ├── FAMILY.md              # Core family context: names, relationships, home, routines
    ├── MERLIN-NOTES.md        # Merlin's contributions for Nimue to read
    └── NIMUE-NOTES.md         # Nimue's contributions for Merlin to read
```

Flat structure — no subfolders. Each agent owns their own `*-NOTES.md` to avoid merge conflicts.

## Implementation

### Phase 1: Create shared repo (Human — requires GitHub)

- [ ] **1.1** Create `markus-barta/oc-workspace-shared` (private repo) on GitHub
- [ ] **1.2** Initialize with:
  - `FAMILY.md` — seed with: Markus + Mailina (married), Maurice (son), home in Graz Austria,
    home automation setup, shared routines, preferences
  - `MERLIN-NOTES.md` — stub: "# Merlin's Notes for Nimue"
  - `NIMUE-NOTES.md` — stub: "# Nimue's Notes for Merlin"
- [ ] **1.3** Grant read/write access to both agent GitHub accounts (`merlin-ai-mba`, `nimue-ai-mai`)
      — or use Markus' PAT via `GITHUB_PAT_MERLIN` (already in container, see Notes)

### Phase 2: nixcfg changes (AI can do — propose + get OK)

- [ ] **2.1** Add shared workspace clone + symlinks to `entrypoint.sh`:
  - Clone/pull `oc-workspace-shared` to `/home/node/.openclaw/workspace-shared/`
  - Create symlinks: `ln -sfn ../workspace-shared /home/node/.openclaw/workspace-merlin/shared`
    and same for Nimue
  - Add daily auto-push loop for shared repo (same pattern as agent workspaces)
  - Use `GITHUB_PAT_MERLIN` for clone/push unless a dedicated PAT is created (see Notes)

- [ ] **2.2** Add `shared` to `.gitignore` in both agent workspace repos
      (`oc-workspace-merlin`, `oc-workspace-nimue`) — prevents git tracking the symlink

- [ ] **2.3** Add shared workspace dir to Dockerfile mkdir block:

  ```dockerfile
  /home/node/.openclaw/workspace-shared \
  ```

- [ ] **2.4** (Optional) Create dedicated `hsb0-shared-github-pat` agenix secret if Merlin's PAT
      should not have write access to the shared repo. Otherwise reuse `GITHUB_PAT_MERLIN`.

### Phase 3: Seed content (Human + AI)

- [ ] **3.1** Populate `FAMILY.md` with real family context (AI drafts, Markus reviews)
- [ ] **3.2** Update both agent `AGENTS.md` files in their workspace repos:
  - "Your workspace contains a `shared/` directory — shared knowledge base with Merlin/Nimue.
    Read it for family context. Write to `shared/MERLIN-NOTES.md` / `shared/NIMUE-NOTES.md`
    when you learn something the other agent should know."

### Phase 4: Verify

- [ ] **4.1** Container boots, shared repo cloned, symlinks present in both workspaces
- [ ] **4.2** `docker exec openclaw-gateway ls workspace-merlin/shared/` shows shared files
- [ ] **4.3** `docker exec openclaw-gateway ls workspace-nimue/shared/` shows same files
- [ ] **4.4** Merlin can answer basic question about Mailina (reads `FAMILY.md` via symlink)
- [ ] **4.5** Nimue can answer basic question about Markus (reads `FAMILY.md` via symlink)
- [ ] **4.6** Merlin writes to `shared/MERLIN-NOTES.md`, commit lands in `oc-workspace-shared`

### Phase 5: Documentation updates (AI can do)

- [ ] **5.1** Update `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`:
  - Add "Shared Workspace" section: purpose, repo, symlink paths, push behavior
  - Add `workspace-shared` row to Files Reference table
- [ ] **5.2** Update both agent `AGENTS.md` files in workspace repos (see Phase 3.2)

## Acceptance Criteria

- [ ] `markus-barta/oc-workspace-shared` exists with `FAMILY.md`, `MERLIN-NOTES.md`, `NIMUE-NOTES.md`
- [ ] Both agent workspaces have a working `shared/` symlink pointing to the shared clone
- [ ] `shared` is in `.gitignore` of both agent workspace repos
- [ ] Both agents can read `FAMILY.md` and answer basic cross-family questions
- [ ] Write → push works for shared repo from inside container
- [ ] OPENCLAW-RUNBOOK.md updated
- [ ] Both agent `AGENTS.md` files reference the shared workspace

## Notes

- **PAT for shared repo**: simplest = reuse `GITHUB_PAT_MERLIN` (already in container, just needs
  access granted to `oc-workspace-shared`). Cleaner alternative: dedicate `hsb0-shared-github-pat`
  agenix secret — better audit trail, minimal extra setup.
- **Merge conflicts**: low risk — each agent writes only to their own `*-NOTES.md`. `FAMILY.md`
  is maintained by Markus, not written by agents.
- **Symlink + git**: git records the symlink as a file (the target path string), not the target
  content. `shared` in `.gitignore` keeps agent workspace repos clean.
- **OpenClaw file reading**: OpenClaw walks the workspace tree and follows symlinks —
  `shared/FAMILY.md` will be visible to each agent as workspace context automatically.
- **Future**: if OpenClaw adds native multi-workspace support, symlinks can be replaced cleanly.
