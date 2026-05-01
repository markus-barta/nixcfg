# AGENTS.MD

Markus owns this. Start: say hi + 1 motivating line when session begins.
Work style: telegraph; noun-phrases ok; minimal grammar; min tokens.

## Response Style

**TL;DR placement rules:**

- Long answers: TL;DR at beginning AND end
- Short answers: TL;DR only at end
- Very short answers: no TL;DR needed
- Use this syntax for TL;DR: "📍 TL;DR: <summary>"

## Agent Protocol

- Contact: Markus Barta (@markus-barta, markus@barta.com).
- Workspace: `~/Code`. Missing a repo? Ask to clone `https://github.com/markus-barta/<repo>.git`.
- 3rd-party/OSS (non-markus-barta): clone under `~/Projects/3rdparty`.
- **Fleet inventory: query FleetCom — do not assume.** Canonical, live source for hosts/agents/services is **FleetCom** at `https://fleet.barta.cm` (repo: `~/Code/fleetcom`). Static lists drift; the live inventory does not. Browse the dashboard for current hosts, status, OS, agent versions. (Programmatic agent access pending — see FleetCom backlog.)
- PRs: use `gh pr view/diff` (no URLs).
- Only edit files in folder `+agents` when user explicitly permits it.
- Use `trash` for deletes, never `rm -rf`.
- Web: search early; Do not guess or invent URLS; quote exact errors; prefer 2026+ sources, fallback to 2025+, then older results.
- Style: Friendly telegraph. Drop filler/grammar. Min tokens.

## Screenshots ("use a screenshot")

- Pick newest PNG in `~/Desktop` or `~/Downloads`.
- Verify it's the right UI (ignore filename).
- If size check is needed: `sips -g pixelWidth -g pixelHeight <file>`.
- If optimize is needed: for macOS `imageoptim <file>` on Linux `image_optim <file>` - STOP and tell user if the tool is missing.

## Important Locations

| What                       | Location/Notes                                      |
| -------------------------- | --------------------------------------------------- |
| NixOS infra config         | `~/Code/nixcfg`                                     |
| "hokage" ref (pbek-nixcfg) | `~/Code/pbek-nixcfg`                                |
| Secrets / credentials      | 1Password (no agent access) — ping Markus           |
| Host runbooks              | `hosts/<hostname>/docs/RUNBOOK.md`                  |
| Agent workflow             | `docs/AGENT-WORKFLOW.md`                            |
| Infrastructure inventory   | `docs/INFRASTRUCTURE.md`                            |
| Task/project mgmt          | PPM (`pm.barta.cm`)                                 |
| **Fleet inventory & status** | **FleetCom (`fleet.barta.cm`) — canonical live source for hosts/agents/services. Query, do not assume.** Repo: `~/Code/fleetcom` |

## Docs

- Start: run `just --list` to see available commands; read docs before coding.
- Follow links until domain makes sense; honor existing patterns.
- Keep notes short; update docs when behavior/API changes (no ship w/o docs).

## Markdown Policy

- **NEVER** create new `.md` files unless user explicitly requests ("create a new doc for X").
- Prefer editing existing docs over creating new ones.
- When asked to "document X": update README.md or RUNBOOK.md, don't create new.
- If tempted to create: ask first ("Should I add this to RUNBOOK.md or create new file?").

## PR Feedback

- Active PR: `gh pr view --json number,title,url --jq '"PR #\\(.number): \\(.title)\\n\\(.url)"'`.
- PR comments: `gh pr view …` + `gh api …/comments --paginate`.
- Replies: cite fix + file/line; resolve threads only after fix lands.

## Flow & Runtime

- Use repo's package manager/runtime; no swaps w/o approval.
- Long jobs: run in background or zellij session.
- Prefix long-running commands (>10s) with `date &&` (bash) or `date; and` (fish).
- Applies to: nix builds, docker ops, large file ops, test suites, package installs.
- When in doubt, add timestamp. Better unnecessary than wondering when it started.

## Build / Test

- Before handoff: run full gate (lint/typecheck/tests/docs).
- CI red: `gh run list/view`, rerun, fix, push, repeat til green.
- Keep it observable (logs, panes, tails).
- Release: read `docs/AGENT-WORKFLOW.md` or relevant checklist.

## Git

- Safe by default: `git status/diff/log`.
- Push is part of the normal flow when working on agreed changes — do it without asking.
- `git checkout` ok for PR review / explicit request.
- Branch changes require user consent.
- Destructive ops forbidden unless explicit (`reset --hard`, `clean`, `restore`, `rm`, …).
- Don't delete/rename unexpected stuff; stop + ask.
- No repo-wide S/R scripts; keep edits small/reviewable.
- No amend unless asked.
- Big review: `git --no-pager diff --color=never`.
- Multi-agent: check `git status/diff` before edits; ship small commits.

## Git Security

**NEVER commit secrets.** Forbidden:

- Plain text passwords, API keys, tokens, bcrypt hashes
- Any `.env` files with real credentials

**Safe to commit:** `.env.example` with placeholders, code referencing env vars.

**Before every commit:** `git diff` to scan for secrets; `git status` to verify files.

**If secrets committed:** STOP AND IMMEDIATELY TELL USER, then discuss → rotate credential → if pushed, assume compromised.

**AI responsibility:** Detect potential secret → STOP → alert user → suggest env var → wait for confirmation.

## Secret Output Safety

**NEVER run commands that print secrets to output.** Forbidden:

- `cat`, `less`, `head`, `tail`, `echo` on any `.env`, `.age`, `.gpg`, `/run/secrets/*`, `/run/agenix/*` files
- `docker exec ... cat /home/node/.env` or any container env file
- `printenv`, `env`, `export` without explicit filtering
- Any command where secrets could appear in stdout/stderr captured by this tool

**If you need to verify a secret exists:** check file existence (`ls -la`) or check a non-secret property. Never print the value.

**If secrets appear in tool output:** STOP. Do not reference, repeat, or quote the values. Inform the user immediately.

## Encrypted Files

**NEVER touch `.age`/`.gpg`/`.enc` files without explicit permission.**

When user wants to modify encrypted content:

1. **ASK**: "I'll need to decrypt. Should I proceed?"
2. **GUIDE**: Provide commands for user to run (`agenix -e secrets/<name>.age`)
3. **VERIFY**: Check file size before/after (encrypted = typically 5KB+)
4. **NEVER** assume permission

**If corrupted:** STOP → alert user → guide restore from git → rotate credential.

## NixOS Build Safety

**NEVER build NixOS configs on macOS.** See `docs/INFRASTRUCTURE.md` for build host availability.

**From macOS, build remotely:**

```bash
# Example for building hsb0 via gpc0 (fastest host)
ssh mba@gpc0.lan "cd ~/Code/nixcfg && sudo nixos-rebuild test --flake .#hsb0"
```

## Critical Thinking

- **Clarity over speed**: If uncertain, ask before proceeding. Better one question than three bugs.
- **Always verify the full context of edits!** Read before replacing.
- Fix root cause (not band-aid).
- Unsure: read more code; if still stuck, ask w/ short options.
- Conflicts: call out; pick safer path.
- Unrecognized changes: assume other agent; keep going; focus your changes. If it causes issues, stop + ask user.
- Leave breadcrumb notes in thread.

## Tools

### just

- Task runner for repo. Run `just --list` to see recipes.
- Common: `just switch`, `just test`, `just encrypt-runbook-secrets`.

### ssh (Host Access)

- **Always check RUNBOOK first** for connection details.
- Home LAN hosts: `ssh mba@<host>.lan` (hsb0, hsb1, hsb8, gpc0)
- Cloud servers: `ssh mba@cs<n>.barta.cm -p 2222` (csb0, csb1)
- imac0 exception: `ssh markus@imac0.lan` (user is markus, not mba!)

### nix / nixos-rebuild / home-manager

- NixOS: `sudo nixos-rebuild switch --flake .#<host>`
- macOS: `home-manager switch --flake .#<host>`
- Check: `nix flake check`
- Update input: `nix flake update <input-name>`

### agenix

- Encrypt: `agenix -e secrets/<name>.age`
- Never touch .age files without explicit permission.

### trash

- Move files to Trash: `trash <file>` (never use `rm -rf`).

### gh

- GitHub CLI for PRs/CI/releases.
- Examples: `gh issue view <url>`, `gh pr view <url> --comments --files`.

### zellij

- Terminal multiplexer (not tmux).
- Use for persistent sessions: servers, long builds, debugging.
- Layouts in `~/.config/zellij/`.

## Task / Backlog Management

All task and backlog management is handled via **PPM** = **Personal Project Management** at `https://pm.barta.cm` (Markus says "ppm" or "PPM" interchangeably). Schema mirrors bp-pm (BYTEPOETS PMO).

- **Auth**: `source ~/Secrets/ppm.env` → exposes `$PPMAPIKEY`. Never cat/read the file. Hostname is `pm.barta.cm` (no `$URL` var in this env file).
- **API**: `curl -s -H "Authorization: Bearer $PPMAPIKEY" https://pm.barta.cm/api/...`
- **Project IDs**: NIX=1 (this repo), DSC26=2, GSC26=3, FLEET=4 (fleetcom), FKID=5 (funkeykid). User `mba` = `user_id=2`.
- **Default for nixcfg work**: project NIX (1). Default for fleetcom work: FLEET (4), parent epic FLEET-1 (id=183).
- **Search before create** to dedupe: `GET /api/search?q=<topic>`.
- **Enums**: type ∈ {epic, ticket, task}; status ∈ {new, backlog, in-progress, qa, done, accepted, invoiced, cancelled}; priority ∈ {low, medium, high}.
- **No markdown backlog files** in this repo (migrated, tagged `backlog-final`).
