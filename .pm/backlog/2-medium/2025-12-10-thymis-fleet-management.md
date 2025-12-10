# Thymis Fleet Management Deployment

**Created**: 2025-12-10
**Priority**: Medium
**Status**: Planning

---

## Goal

Deploy [Thymis](https://github.com/Thymis-io/thymis) as a web-based fleet management platform for all NixOS hosts, with visibility into macOS hosts.

---

## Decisions Made

### Workflow Architecture: Hybrid (Option C)

- **Major changes**: Cursor/SYSOP → GitHub → Thymis pulls → Deploy
- **Quick fixes**: Thymis Web UI → commits to Git → Deploy
- **Git remains source of truth**

### macOS Host Management

- **No automation** — full manual control via Cursor/SYSOP
- **Visibility**: Option 1 (native Thymis monitor-only) preferred
- **Fallback**: Option 3 (separate Fleet Overview page) if Thymis doesn't support monitor-only

### Human-in-the-Loop Policy

**Phase 1 (Initial)**: All hosts require manual approval

| Host | Policy                      |
| ---- | --------------------------- |
| All  | ⏸️ Manual approval required |

**Phase 2 (Future graduation)**:

| Host             | Unlock Criteria                   |
| ---------------- | --------------------------------- |
| gpc0             | First to auto-deploy (guinea pig) |
| hsb1, hsb8, csb1 | After gpc0 stable 2+ weeks        |
| hsb0, csb0       | Last (maybe never auto)           |

### Domain

- **URL**: `thymis.barta.cm` (not thymis.cs1.barta.cm)

---

## Architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│                        HYBRID WORKFLOW                           │
└──────────────────────────────────────────────────────────────────┘

  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐
  │   Cursor +   │  push   │    GitHub    │  pull   │    Thymis    │
  │  SYSOP Agent │ ──────► │   nixcfg     │ ◄────── │  Controller  │
  │              │         │              │         │   (csb1)     │
  └──────────────┘         └──────────────┘         └──────┬───────┘
                                                           │
                                                           │ Deploy
                                                           ▼
                                                    ┌─────────────┐
                                                    │   Agents    │
                                                    │ hsb0, hsb1  │
                                                    │ hsb8, gpc0  │
                                                    │ csb0        │
                                                    └─────────────┘
```

---

## Acceptance Criteria

### Phase 1: Controller Setup

- [ ] Thymis controller running on csb1
- [ ] Accessible at <https://thymis.barta.cm>
- [ ] Cloudflare DNS configured for thymis.barta.cm → csb1
- [ ] Traefik routing configured
- [ ] External repository (nixcfg) linked

### Phase 2: NixOS Agent Deployment

- [ ] Agent deployed to gpc0 (guinea pig)
- [ ] Agent deployed to hsb1
- [ ] Agent deployed to hsb8
- [ ] Agent deployed to hsb0
- [ ] Agent deployed to csb0
- [ ] All agents visible in Thymis dashboard
- [ ] Manual approval workflow tested

### Phase 3: macOS Visibility

- [ ] Research: Does Thymis support monitor-only hosts?
- [ ] If yes: Configure imac0, mba-imac-work, mba-mbp-work as monitor-only
- [ ] If no: Implement Fleet Overview fallback (Option 3)
- [ ] All 9 hosts visible in single dashboard

### Phase 4: Documentation

- [ ] INFRASTRUCTURE.md updated with full details
- [ ] AGENT-WORKFLOW.md updated with operational reference
- [ ] Host READMEs updated to mention Thymis agent

---

## Implementation Notes

### Thymis External Repository Setup

Thymis supports [external Git repositories](https://thymis.io/docs/external-projects/external-repositories):

1. nixcfg already has `flake.nix` — compatible
2. Configure Thymis to watch GitHub repo
3. On push: Thymis pulls, builds, waits for approval

### Hosts to Manage

| Host          | Type  | Thymis Role        |
| ------------- | ----- | ------------------ |
| csb1          | NixOS | Controller         |
| hsb0          | NixOS | Agent              |
| hsb1          | NixOS | Agent              |
| hsb8          | NixOS | Agent              |
| csb0          | NixOS | Agent              |
| gpc0          | NixOS | Agent              |
| imac0         | macOS | Monitor-only (TBD) |
| mba-imac-work | macOS | Monitor-only (TBD) |
| mba-mbp-work  | macOS | Monitor-only (TBD) |

---

## Risks

| Risk                                    | Mitigation                            |
| --------------------------------------- | ------------------------------------- |
| Thymis doesn't support macOS monitoring | Fallback to Option 3 (Fleet Overview) |
| Build performance on csb1               | Consider remote builds to gpc0        |
| Internet required for home hosts        | Agents reconnect automatically        |

---

## References

- [Thymis GitHub](https://github.com/Thymis-io/thymis)
- [Thymis Docs](https://thymis.io/docs)
- [External Repositories](https://thymis.io/docs/external-projects/external-repositories)
- [docs/INFRASTRUCTURE.md](../../docs/INFRASTRUCTURE.md) — Architecture diagrams
