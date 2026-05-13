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

| What                         | Location/Notes                                                                                                                   |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| NixOS infra config           | `~/Code/nixcfg`                                                                                                                  |
| "hokage" ref (pbek-nixcfg)   | `~/Code/pbek-nixcfg`                                                                                                             |
| Secrets / credentials        | 1Password (no agent access) — ping Markus                                                                                        |
| Host runbooks                | `hosts/<hostname>/docs/RUNBOOK.md`                                                                                               |
| Agent workflow               | `docs/AGENT-WORKFLOW.md`                                                                                                         |
| Infrastructure inventory     | `docs/INFRASTRUCTURE.md`                                                                                                         |
| Task/project mgmt            | PPM (`pm.barta.cm`)                                                                                                              |
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

**NEVER run commands that print secrets to output.**

### The principle (read this, not just the list below)

Secrets must not appear in stdout, stderr, or any tool output the agent harness captures. Every "forbidden command" in the list below is a specific instance of this principle. When evaluating a new command, **apply the principle, not the list** — the list will never be exhaustive.

### Forbidden commands (hard list — never run, no exceptions)

These commands ALWAYS expose secret values when run against this repo's secret pipeline (m5, imac0, imacw materialize `~/.inspr/secrets/agents/*.env` containing API tokens + SSH private keys). NEVER invoke them, even "just to verify a fix":

- `direnv export <shell>` — emits resolved env as `export VAR=$'<plaintext-value>'` to stdout. Functionally identical to `printenv` for any var .envrc loaded.
- `direnv status` (when active) — may leak a subset
- `env`, `printenv` (without naming a specific non-sensitive variable)
- `set`, `declare -x`, `declare -p`, `compgen -e`, `export -p`
- `cat`/`less`/`head`/`tail`/`bat`/`xxd`/`od`/`hexdump`/`strings` on:
  - any file under `~/.inspr/secrets/`
  - any file under `~/Secrets/` (legacy path, INSPR-164)
  - any file under `/run/agenix/` or `/run/secrets/`
  - any path matching `*.env`, `*.age`, `*.gpg`, `*.enc`, `*.key`, `id_*` (unless `.pub`), `*_rsa`, `*_ed25519`
  - any `~/.ssh/` file lacking `.pub` extension
- Container/k8s "resolved" config peek: `docker exec <c> cat /home/node/.env`, `kubectl get secret -o yaml`, `kubectl describe configmap` after env expansion. Work from the **git-source file** which keeps `${VAR}` placeholders intact.
- Any pipe where a secret-bearing file is read, sourced, or env-expanded into a downstream-visible position (e.g. `source <env-file>; env`, `agenix -d <file>.age` to stdout).

### Safe verification primitives

When you need to verify the secret pipeline works, use these — they prove the property WITHOUT revealing values:

| Goal                                            | Safe command                                                                                                                                                                                                                    |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Count materialized env files                    | `ls ~/.inspr/secrets/agents/*.env \| wc -l`                                                                                                                                                                                     |
| Verify a specific var IS set                    | `[ -n "${VAR:-}" ] && echo "set"` (never `echo "$VAR"`)                                                                                                                                                                         |
| Verify .envrc didn't error                      | `direnv reload 2>&1 \| grep -ciE "command not found\|begin (openssh\|rsa)"` (count only — never print matched lines)                                                                                                            |
| Verify direnv exports the right NAMES           | `direnv export bash 2>/dev/null \| grep -oE "^export [A-Z_][A-Z0-9_]*=" \| sort -u` ← narrow exception: the `=` is the cut-point, the regex strips values by construction. **Don't mutate this without testing offline first.** |
| Check file content TYPE without reading content | `file ~/.inspr/secrets/agents/SOMETHING.env`                                                                                                                                                                                    |
| Confirm decrypt would work                      | `age -d -i ~/.ssh/id_ed25519 <file>.age > /dev/null` (redirect to /dev/null, check exit code)                                                                                                                                   |

### Pre-flight checklist (run this in your head before EVERY Bash command)

1. **Could this command's stdout/stderr contain a secret value?** If yes → use a safe primitive above, OR ask the user.
2. **Does the command touch any of**: `~/Secrets/`, `~/.inspr/secrets/`, `~/.ssh/<not-pub>`, `/run/agenix/`, `*.env`, `*.age`, `*.gpg`?
   If yes → re-verify #1 with extra scrutiny.
3. **Does the command involve any of**: `env`, `printenv`, `set`, `export`, `declare`, `direnv export`, `direnv status`, `source`, `cat`, `head`, `tail`, `less`, `bat`?
   If yes → STOP. Default-assume #1 = yes until proven otherwise.
4. **Did a filtered command return empty unexpectedly?** Do NOT remove the filter and re-run. Diagnose the underlying state (the filter was probably correct; the state was wrong).

### If secrets DO appear in output (incident response)

1. **STOP** — do not run further commands that could touch the same secret pipeline
2. **Inform the user immediately** — name the affected variables (NEVER the values)
3. **Rotate** every exposed credential before continuing
4. **Document** the incident path so the guardrail can be tightened

### Past incidents (case studies)

- **2026-05-13, Ghostty scrollback leak**: imacw's `.envrc` blindly sourced all `*.env` files in the agent-secrets dir, including SSH private keys with `.env` extension (per INSPR-170 atelier userkey naming convention). Bash printed each base64 line as `<bytes>: command not found` over SSH to imac0's Ghostty buffer. Mitigation: content-aware filter in `.envrc` (this repo, ship 2026-05-13). Architectural follow-up: separate paths per content-type (env vars vs SSH keys) — see INSPR backlog.

- **2026-05-13, `direnv export bash` leak**: agent ran `direnv export bash` to verify the `.envrc` content-filter fix. That command dumps the resolved environment as `export VAR=$'value'` — every secret loaded by direnv (PPMAPIKEY, PMOAPIKEY, GH*TOKEN, CF*\*, …) hit stdout → agent context + user terminal. Root cause: agent treated `direnv export` as a "diagnostic" not as a `printenv` equivalent. Forbidden-commands list above tightened to enumerate `direnv export` explicitly. Safe alternative documented for this exact verify (count `command not found` matches, OR pipe through `grep -oE "^export [A-Z_]+="` to strip values).

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

- **Auth**: `set -a; source ~/.inspr/secrets/agents/PPMAPIKEY.env; set +a` → exposes `$PPMAPIKEY`. Materialized by `inspr.secrets.agents` HM module (file is `KEY=value`, no `export`; see `docs/SECRETS.md`). Canonical fleet-wide path (INSPR-164, 2026-05-13). Direnv already does this for shells in `~/Code/nixcfg`. Never cat/read the file. Hostname is `pm.barta.cm` (no `$URL` var in this env file).
- **API**: `curl -s -H "Authorization: Bearer $PPMAPIKEY" https://pm.barta.cm/api/...`
- **Project IDs**: NIX=1 (this repo), DSC26=2, GSC26=3, FLEET=4 (fleetcom), FKID=5 (funkeykid). User `mba` = `user_id=2`.
- **Default for nixcfg work**: project NIX (1). Default for fleetcom work: FLEET (4), parent epic FLEET-1 (id=183).
- **Search before create** to dedupe: `GET /api/search?q=<topic>`.
- **Enums**: type ∈ {epic, ticket, task}; status ∈ {new, backlog, in-progress, qa, done, accepted, invoiced, cancelled}; priority ∈ {low, medium, high}.
- **No markdown backlog files** in this repo (migrated, tagged `backlog-final`).
