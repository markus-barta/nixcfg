# AGENTS.MD

Markus owns this. Start: say hi + 1 motivating line.
Work style: telegraph; noun-phrases ok; minimal grammar; min tokens.

## Response Style

**TL;DR placement rules:**

- Long answers: TL;DR at beginning AND end
- Short answers: TL;DR only at end
- Very short answers: no TL;DR needed
- Use this syntax for TL;DR: "📍 TL;DR: <summary>"

## Agent Protocol

- Contact: Markus Barta (@markus-barta, markus@barta.com).
- Workspace: `~/Code`. Missing a repo? Clone `https://github.com/markus-barta/<repo>.git`.
- 3rd-party/OSS (non-markus-barta): clone under `~/Projects/3rdparty`.
- Work devices: `imac0` (home iMac), `mba-imac-work` (work iMac), `mba-mbp-work` (portable MacBook).
- PRs: use `gh pr view/diff` (no URLs).
- Only edit AGENTS when user says "edit AGENTS.md"
- Guardrails: use `trash` for deletes, never `rm -rf`.
- Web: search early; quote exact errors; prefer 2024–2025 sources.
- Style: telegraph. Drop filler/grammar. Min tokens.

## Screenshots ("use a screenshot")

- Pick newest PNG in `~/Desktop` or `~/Downloads`.
- Verify it's the right UI (ignore filename).
- Size check: `sips -g pixelWidth -g pixelHeight <file>`.
- Optimize: for macOS `imageoptim <file>`; on Linux `image_optim <file>`.

## Important Locations

| What                        | Location/Notes                            |
| --------------------------- | ----------------------------------------- |
| NixOS infra config          | `~/Code/nixcfg`                           |
| NixFleet (dashboard, agent) | `~/Code/nixfleet`                         |
| "hokage" ref (pbek-nixcfg)  | `~/Code/pbek-nixcfg`                      |
| Secrets / credentials       | 1Password (no agent access) — ping Markus |
| Host runbooks               | `hosts/<hostname>/docs/RUNBOOK.md`        |
| Agent workflow              | `docs/AGENT-WORKFLOW.md`                  |
| Infrastructure inventory    | `docs/INFRASTRUCTURE.md`                  |
| Task/project mgmt           | `+pm/` in repo                            |

## Docs

- Start: run `just --list` to see available commands; read docs before coding.
- Follow links until domain makes sense; honor existing patterns.
- Keep notes short; update docs when behavior/API changes (no ship w/o docs).
- Model preference (descending): Claude Opus 4.5, Gemini 3 Flash, Composer 1 (Cursor).

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

## Command Timestamps

- Prefix long-running commands (>10s) with `date &&` (bash) or `date; and` (fish).
- Applies to: nix builds, docker ops, large file ops, test suites, package installs.
- When in doubt, add timestamp. Better unnecessary than wondering when it started.

## Build / Test

- Before handoff: run full gate (lint/typecheck/tests/docs).
- CI red: `gh run list/view`, rerun, fix, push, repeat til green.
- Keep it observable (logs, panes, tails).
- Release: read `docs/AGENT-WORKFLOW.md` or relevant checklist.

## Git

- Safe by default: `git status/diff/log`. Push only when user asks.
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

**If secrets committed:** STOP → `git reset --soft HEAD~1` → rotate credential → if pushed, assume compromised.

**AI responsibility:** Detect potential secret → STOP → alert user → suggest env var → wait for confirmation.

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

## Starship Config

## Critical Thinking

- **Clarity over speed**: If uncertain, ask before proceeding. Better one question than three bugs.
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
