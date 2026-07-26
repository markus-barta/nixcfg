# nixcfg — Agent Doctrine Overlay

_nixcfg-specific delta only. Universal rules: the auto-loaded kernel (`doctrine/docs/AGENTS-KERNEL.md`); depth via `/dev /secrets /nix /ops /ppm /style /incident /inspr`. **Host behaviour** lives in PAIMOS **OPS** runbooks tagged `host:<name>`, not here._

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

## Committing

- 🔴 Never commit **MAC addresses**, **PII** (family names, personal emails, phone numbers), or plaintext secrets / decrypted `~/Secrets/` content. MAC addresses and SSH private keys may appear **only** inside agenix-encrypted `.age` files.

## agenix & secret rotation

- 🔴 **A global rekey can SILENTLY WIPE secrets** when an SSH key is missing. After `just rekey`, check file sizes — **~578 bytes means corrupted, header only**. Verify with `git diff --stat` **before** committing rekeyed secrets.
- 🔴 **If you see 578-byte files: STOP.** Do not commit, push, rekey again, or alter the affected files. Preserve evidence, identify the exact affected paths and a validated known-good recovery source, then get explicit user approval before recovering **only those paths**. Never reset or restore the whole worktree.
- 🔴 In Nix configs, reference passwords via a `_File` path (`config.age.secrets.<name>.path`) — never inline plaintext.
- 🔴 After secret rotation: `gitpl && just switch && just <container>-rebuild`. `just switch` is **required** — agenix decrypts on NixOS switch, not on docker rebuild.
- 🟡 Tier-1 system secrets live in `secrets/` (NixOS servers); use agenix and the `just edit-secret` commands.
- 🟡 Materialized agent secret files are mode `0400` in a `0500` directory — read-only, one-way.
- 🟡 A macOS host needs a one-time `sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key` before it can act as an agenix recipient.

## SSH keys

- 🔴 Family servers (`hsb0`, `hsb8`) **MUST NOT** admit external developer keys — always `lib.mkForce` on `authorizedKeys` to block upstream-profile key injection. hsb0 allows `mba` only. _(incident 2025-11-22)_

## Build safety

- 🔴 Define static networking **declaratively** for servers, and set `hashedPassword` on `mba` so VNC console recovery is possible. _(incident 2025-12-05)_
- 🔴 Verify the gateway via DHCP (`journalctl` or `ip route`) **before** applying static IP config. _(incident 2025-12-06)_
- 🔴 Use `lib.mkForce` for restic capabilities in `modules/common.nix` — duplicated capabilities cause **SSH lockout**.
- 🔴 Never hand-edit files on a server. Edit compose locally → commit → push → `git pull` on the host → `docker compose up -d`.
- 🔴 On `hsb1`, every managed file must be a **symlink back to nixcfg**. If it is not a symlink, it is not managed.

## Repo conventions

- 🔴 Edit the canonical files in `+agents/rules/`, never the symlink targets — and only when the user explicitly permits editing `+agents/`.
- 🔴 Never hand-edit `modules/uzumaki/stasysmo/icons.sh` — regenerate with the Python helper to preserve Unicode.
- 🔴 No markdown backlog files in nixcfg — the backlog lives in PPM.
- 🟡 Default PPM project here is **NIX** (id 1). Route new work by the NIX / OPS / AIA tie-breaker: _a module builds correctly_ → NIX; _a service or host behaves_ → OPS; _an agent's behaviour_ → AIA; ambiguous → OPS.
- 🟡 `just --list` at session start. Check the host RUNBOOK before SSH.

## hsb1 Home Assistant — duplicated here on purpose

Incident-derived (2026-03-20), so they must be visible while editing `hosts/hsb1/` without loading a runbook. Full set: OPS runbook `host:hsb1`.

- 🔴 Never target `entity_id: "all"`, or an area, without reviewing exactly which entities are in scope — **explicit entity lists only**.
- 🔴 Never use WiFi presence to trigger device control or destructive actions (e.g. turning off lights).

## Host behaviour → OPS runbooks

Not in this file (OPS charter + NIX/OPS boundary). PAIMOS **OPS** runbooks `host:{hsb1,csb0,csb1,hsb8,hsb2,gpc0}` + guideline `cloudflare-dns-proxy-policy`.

---

_Provenance: git history (`git log -S'<rule text>' -- AGENTS.md`) and the source docs under `docs/`, `hosts/*/docs/`, `+agents/rules/`. Inline `src:` footers dropped 2026-07-26 — 23% had drifted to lines no longer mentioning their rule._
