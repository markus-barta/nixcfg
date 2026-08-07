# nixcfg — repo delta

_Loaded by `CLAUDE.md` alongside the kernel. nixcfg-specific rules only — universal rules are in the kernel, depth via `/dev /secrets /nix /ops /ppm /style /incident /inspr`, host behaviour in PAIMOS **OPS** runbooks `host:<name>`._

## Committing

- 🔴 Never commit **MAC addresses**, **PII** (family names, personal emails, phone numbers), or plaintext secrets / decrypted `~/Secrets/` content. MAC addresses and SSH private keys belong **only** inside agenix-encrypted `.age` files.

## agenix

- 🔴 **A global rekey can SILENTLY WIPE secrets** when an SSH key is missing. After `just rekey`, check file sizes — **~578 bytes means corrupted, header only**. Verify with `git diff --stat` **before** committing rekeyed secrets. **If you see 578-byte files: STOP** — do not commit, push, rekey again, or alter them. Recovery procedure: NIX runbook `agenix-rekey-safety`.
- 🔴 Reference passwords via a `_File` path (`config.age.secrets.<name>.path`) — never inline plaintext.
- 🔴 After rotation: `gitpl && just switch && just <container>-rebuild`. `just switch` is **required** — agenix decrypts on NixOS switch, not on docker rebuild.
- 🟡 Layout, file modes, macOS recipient enrolment: NIX runbook `agenix-rekey-safety`.

## SSH keys

- 🔴 Family servers (`hsb0`, `hsb8`) **MUST NOT** admit external developer keys — always `lib.mkForce` on `authorizedKeys` to block upstream-profile key injection. hsb0 allows `mba` only. _(incident 2025-11-22)_

## Build safety

- 🔴 Define static networking **declaratively** for servers, and set `hashedPassword` on `mba` so VNC console recovery is possible. _(incident 2025-12-05)_
- 🔴 Verify the gateway via DHCP (`journalctl` or `ip route`) **before** applying static IP config. _(incident 2025-12-06)_
- 🔴 `lib.mkForce` for restic capabilities in `modules/common.nix` — duplicated capabilities cause **SSH lockout**.
- 🔴 Never hand-edit files on a server. Edit compose locally → commit → push → `git pull` on the host → `docker compose up -d`.
- 🔴 On `hsb1`, every managed file must be a **symlink back to nixcfg**. Not a symlink = not managed.

## Repo conventions

- 🔴 Edit the canonical files in `+agents/rules/`, never the symlink targets — and only when explicitly permitted to touch `+agents/`.
- 🔴 Never hand-edit `modules/uzumaki/stasysmo/icons.sh` — regenerate with the Python helper to preserve Unicode.
- 🔴 No markdown backlog files — the backlog lives in PPM.
- 🟡 Default PPM project **NIX** (id 1). Routing between NIX / OPS / AIA: OPS guideline `nix-ops-aia-boundary`.
- 🟡 `just --list` at session start. Check the host RUNBOOK before SSH.

## hsb1 Home Assistant — duplicated here on purpose

Incident-derived (2026-03-20), so they stay visible while editing `hosts/hsb1/`. Full set: OPS runbook `host:hsb1`.

- 🔴 Never target `entity_id: "all"`, or an area, without reviewing exactly which entities are in scope — **explicit entity lists only**.
- 🔴 Never use WiFi presence to trigger device control or destructive actions (e.g. turning off lights).

## Host behaviour → OPS

Not here. PAIMOS **OPS** runbooks `host:{hsb1,csb0,csb1,hsb8}` + guideline `cloudflare-dns-proxy-policy`. Rekey depth: NIX runbook `agenix-rekey-safety`.

_Provenance: `git log -S'<rule text>'` and the source docs under `docs/`, `hosts/*/docs/`, `+agents/rules/`._
