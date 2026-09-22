# nixcfg — Agent Doctrine Overlay

> **Read `AGENTS-NIXCFG.md` now** — it holds this repo's actual rules (agenix, build safety, SSH keys, repo conventions). This file carries only the hard-safety subset below, for tools that don't follow `@-ref`s.
>
> Claude Code loads `doctrine/docs/AGENTS-KERNEL.md` + `AGENTS-NIXCFG.md` via `CLAUDE.md` and does **not** need this file.

<!-- KERNEL-MIRROR-BEGIN — 🔴 subset of doctrine/docs/AGENTS-KERNEL.md for tools that don't follow the CLAUDE.md @-ref (Cursor, Aider, OpenCode, Codex CLI). Claude Code already has the full kernel. Re-mirror after `git submodule update --remote doctrine`. -->

## Worker routing (kernel mirror)

**Version-bearing work:** load `AGENTS-VERSIONING.md` (or the installed `inspr-worker-doctrine` reference) at project bootstrap and before release/deployment. INSPR Calendar Versioning is the default: pick up existing adoption tickets for the next deployment; without one, propose and track adoption; adopted projects review their saved presentation pin. Preserve migration/review gates and historical artifacts.

**Model choice:** evaluate the task, pick a role — `scout` · `mechanical` · `build` · `build-hard` · `review-gate` — and resolve it with `paimos model resolve <role> [--author-family <yours>]`; run the command it prints. Model names live in the Paimos registry (catalog, cross-family review ladder, expiring overrides — PAI-1048), never in doctrine, skills or prompts; the only exceptions are lenses defined by one exact model, enumerated in `/dev` § model choice by role.

## Hard safety (kernel mirror — 🔴 only)

- **Identity**: Markus Barta, `markus@barta.com`, `markus-barta`. Never invent placeholders.
- 🔴 **Never read secrets**: no `cat/Read/head/tail/less/bat/xxd/od/sed/grep/strings` on `~/.inspr/secrets/agents/`, `~/Secrets/`, `~/.ssh/<not-pub>`, `/run/agenix/`, `/run/secrets/`, `*.env`, `*.age`, `*.gpg`, `id_*`, `*_rsa`, `*_ed25519`. Source via `( set -a; source FILE; cmd; set +a )`; existence check `[ -n "$VAR" ]`. Never dump the environment (`direnv export`, `set`, `declare -x`, `export -p`, `env`, `printenv`, `docker inspect`). 1Password is canonical. Secret in output → **STOP**, name vars not values, rotate.
- 🔴 **Git**: no `reset --hard` / `clean -f` / `restore .` / `checkout .` / `branch -D` / `rm`; no `--force` to main; no `--no-verify` / `--no-gpg-sign` / `--amend`; never commit secrets. `git diff` + `git status` before every commit.
- 🔴 **Cross-repo authoring**: author changes only in the session's own repo; everywhere else file a ticket in the owning project with the proposed diff (reading is unrestricted, only writes are governed). One carve-out — release pins: edit only the pin, its comment, and whatever the documented vendoring step also requires (e.g. re-mirroring a doctrine block), with a recorded rollback path. Where a review path exists, use it (PR + checks — never a direct push to `main`, even where `main` is unprotected); where none exists, the owner's explicit request for that specific change is the gate — never agent initiative. Third-party / business-owned repos and no review path → STOP and ask. Delete only branches you created.
- 🔴 **Files**: `trash`, not `rm -rf`. Never delete/rename unexpected items — ask. Encrypted files only with permission. **Never build NixOS on macOS** (build remotely; macOS HM is fine). No new `.md` unless asked — durable knowledge → PPM.
- 🔴 **Trust contexts**: personal / INSPR (FOSS, `inspr-at`) / augmentoring (client work, e.g. `dsccfg`). Classify by ownership of output, never by GitHub org. Never cross with credentials or tickets.
- **`.cm`** TLD intentional, never `.com`. INSPR is the umbrella (FleetCom archived → Pharos).

<!-- KERNEL-MIRROR-END -->

---

_Repo rules: **`AGENTS-NIXCFG.md`**. Host behaviour: PAIMOS **OPS** runbooks `host:<name>`. Full doctrine: `doctrine/docs/AGENTS-KERNEL.md`._
