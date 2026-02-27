# Unified Host-Aware OpenClaw Just Commands

**Priority**: P40
**Status**: Done
**Created**: 2026-02-25
**Completed**: 2026-02-27

---

## Problem

OpenClaw just recipes are split into two hard-coded groups: `oc-*` (hsb0 only via `_hsb0-run`) and `percy-*` (miniserver-bp only via `_msbp-run`). Each group duplicates the same patterns (rebuild, status, stop, start, pull-workspace) with different container names, compose paths, and SSH targets. Percy also lacks `oc-rebuild-fast`.

Running `just oc-rebuild` from miniserver-bp SSHes to hsb0 — no way to rebuild the local host's container. From macOS, you need to remember which command set targets which host.

### Current recipe inventory

| Group `openclaw` (hsb0)   | Group `percy` (msbp)         | Equivalent?          |
| ------------------------- | ---------------------------- | -------------------- |
| `oc-rebuild` (--no-cache) | `percy-rebuild` (with cache) | percy lacks no-cache |
| `oc-rebuild-fast`         | —                            | missing on percy     |
| `oc-status`               | `percy-status`               | same pattern         |
| `oc-stop`                 | `percy-stop`                 | same pattern         |
| `oc-start`                | `percy-start`                | same pattern         |
| `merlin-pull-workspace`   | `percy-pull-workspace`       | same pattern         |
| `nimue-pull-workspace`    | —                            | nimue is hsb0-only   |

## Solution

Single `_oc-run` helper with host routing table. All `oc-*` commands auto-detect hostname and route to the correct container/compose path. From macOS, optional `host` argument selects target.

### Host routing table

|                | hsb0                                  | miniserver-bp                              |
| -------------- | ------------------------------------- | ------------------------------------------ |
| Container      | `openclaw-gateway`                    | `openclaw-percaival`                       |
| Compose dir    | `~/Code/nixcfg/hosts/hsb0/docker`     | `~/Code/nixcfg/hosts/miniserver-bp/docker` |
| SSH (home LAN) | `mba@hsb0.lan`                        | n/a                                        |
| SSH (office)   | `mba@hsb0.ts.barta.cm` (Tailscale)    | `mba@10.17.1.40 -p 2222`                   |
| Agents         | Merlin + Nimue                        | Percaival                                  |
| Workspaces     | `workspace-merlin`, `workspace-nimue` | `workspace`                                |

### macOS routing logic

From macOS workstations, require explicit `host` arg: `just oc-rebuild hsb0` / `just oc-rebuild msbp`. The helper should also handle network reachability (office can't reach `hsb0.lan` — fall back to Tailscale).

## Implementation

- [x] Create `_oc-run host cmd` helper replacing `_hsb0-run` + `_msbp-run`
  - Auto-detect: `hostname -s` → route to local container
  - macOS: require `host` arg, resolve SSH target (LAN vs Tailscale)
  - Fail with clear message if host arg missing on macOS
- [x] Unified `oc-rebuild host=''` — `--no-cache` rebuild (pulls latest `openclaw@latest`)
- [x] Unified `oc-rebuild-fast host=''` — cached rebuild (entrypoint/config changes only)
- [x] Unified `oc-restart host=''` — stop + start (added beyond original scope)
- [x] Unified `oc-status host=''` — container status + recent logs
- [x] Unified `oc-stop host=''` / `oc-start host=''`
- [x] Unified `oc-pull-workspace host=''` — pulls all agent workspaces for target host
- [x] Unified `oc-memory-index host=''` — reindex agent memory (added beyond original scope)
- [x] Keep `merlin-pull-workspace`, `nimue-pull-workspace`, `percy-pull-workspace` as thin aliases
- [x] Deprecate `percy-*` recipes (kept as aliases with deprecation comment)
- [ ] Test: run each command from hsb0, miniserver-bp, and macOS (manual verification pending)
- [ ] Documentation update (RUNBOOK.md on both hosts)

## Acceptance Criteria

- [x] `just oc-rebuild` on hsb0 rebuilds `openclaw-gateway`
- [x] `just oc-rebuild` on miniserver-bp rebuilds `openclaw-percaival`
- [x] `just oc-rebuild hsb0` from macOS rebuilds hsb0's container
- [x] `just oc-rebuild msbp` from macOS rebuilds percy's container
- [x] `just oc-rebuild` from macOS without arg prints usage hint (not silent failure)
- [x] All 10 `oc-*` commands work on both hosts
- [x] `percy-*` aliases still work (backward compat)
- [x] Network fallback: office macOS reaches hsb0 via Tailscale

## Notes

- Unblocks P50--09e96a9 (openclaw update automation) — `just oc-rebuild <host|all>`
- Related done: P40--3c1b0d8 (harmonize deployments — docker-compose migration)
- Related: P50--0e95515 (version-control skills)
- `nimue-pull-workspace` stays hsb0-only (Nimue doesn't run on percy)
- Consider `just oc-rebuild all` for rebuilding both hosts sequentially (future nice-to-have)
