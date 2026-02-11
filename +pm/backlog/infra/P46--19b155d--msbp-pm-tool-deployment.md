# msbp: pm-tool Deployment Pipeline

**Created**: 2026-02-09
**Priority**: P4600 (Medium)
**Status**: Backlog
**Depends on**: P4550 (Docker infra), P4650 (repo scaffolding)

---

## Problem

Need a build & deploy workflow for pm-tool on msbp. Must account for msbp's weak CPU — builds should happen elsewhere.

---

## Solution

### Build Strategy

**Do NOT build on msbp.** Core 2 Duo cannot handle Go + Vue builds efficiently.

Options (in order of preference):

1. **GitHub Actions** — build Docker image, push to GHCR, pull on msbp
2. **Build on mba-imac-work** — `docker build`, `docker save | ssh ... docker load`
3. **Build on gpc0** — fastest build host (but home network, not always reachable from office)

### Deploy Strategy

```
GitHub push → GHCR image → msbp pulls & restarts
```

Or manual for now:

```bash
# From mba-imac-work (office network)
ssh -p 2222 mba@10.17.1.40 "cd ~/Code/pm-tool && docker compose pull && docker compose up -d"
```

### NixOS Integration

Replace hello-world container with pm-tool once ready:

```nix
virtualisation.oci-containers.containers.pm-tool = {
  image = "ghcr.io/markus-barta/pm-tool:latest";
  ports = [ "8888:8888" ];
  volumes = [ "/var/lib/pm-tool/data:/app/data" ];  # SQLite db
};
```

---

## Acceptance Criteria

- [ ] Docker image builds successfully (multi-stage: Go + Vue)
- [ ] Image size < 50MB (Alpine-based)
- [ ] Deploy to msbp works (manual or automated)
- [ ] SQLite data persists across container restarts (volume mount)
- [ ] Rollback possible (previous image tag)

---

## Risk

🟢 LOW — test server, no production impact

---

## Related

- P4500: pm-tool PRD
- P4550: msbp Docker infrastructure
- P4650: pm-tool repo scaffolding
