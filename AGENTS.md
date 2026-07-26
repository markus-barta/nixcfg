# nixcfg — Agent Doctrine Overlay

> **Read `AGENTS-NIXCFG.md` now** — it holds this repo's actual rules (agenix, build safety, SSH keys, repo conventions). This file carries only the hard-safety subset below, for tools that don't follow `@-ref`s.
>
> Claude Code loads `doctrine/docs/AGENTS-KERNEL.md` + `AGENTS-NIXCFG.md` via `CLAUDE.md` and does **not** need this file.

<!-- KERNEL-MIRROR-BEGIN — 🔴 subset of doctrine/docs/AGENTS-KERNEL.md for tools that don't follow the CLAUDE.md @-ref (Cursor, Aider, OpenCode, Codex CLI). Claude Code already has the full kernel. Re-mirror after `git submodule update --remote doctrine`. -->

## Hard safety (kernel mirror — 🔴 only)

- **Identity**: Markus Barta, `markus@barta.com`, `markus-barta`. Never invent placeholders.
- 🔴 **Never read secrets**: no `cat/Read/head/tail/less/bat/xxd/od/sed/grep/strings` on `~/.inspr/secrets/agents/`, `~/Secrets/`, `~/.ssh/<not-pub>`, `/run/agenix/`, `/run/secrets/`, `*.env`, `*.age`, `*.gpg`, `id_*`, `*_rsa`, `*_ed25519`. Source via `( set -a; source FILE; cmd; set +a )`; existence check `[ -n "$VAR" ]`. Never dump the environment (`direnv export`, `set`, `declare -x`, `export -p`, `env`, `printenv`, `docker inspect`). 1Password is canonical. Secret in output → **STOP**, name vars not values, rotate.
- 🔴 **Git**: no `reset --hard` / `clean -f` / `restore .` / `checkout .` / `branch -D` / `rm`; no `--force` to main; no `--no-verify` / `--no-gpg-sign` / `--amend`; never commit secrets. `git diff` + `git status` before every commit.
- 🔴 **Files**: `trash`, not `rm -rf`. Never delete/rename unexpected items — ask. Encrypted files only with permission. **Never build NixOS on macOS** (build remotely; macOS HM is fine). No new `.md` unless asked — durable knowledge → PPM.
- 🔴 **Trust contexts**: personal / INSPR (FOSS, `inspr-at`) / augmentoring (client work, e.g. `dsccfg`). Classify by ownership of output, never by GitHub org. Never cross with credentials or tickets.
- **`.cm`** TLD intentional, never `.com`. INSPR is the umbrella (FleetCom archived → Pharos).

<!-- KERNEL-MIRROR-END -->

---

_Repo rules: **`AGENTS-NIXCFG.md`**. Host behaviour: PAIMOS **OPS** runbooks `host:<name>`. Full doctrine: `doctrine/docs/AGENTS-KERNEL.md`._
