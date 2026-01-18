# P1505 - csb0 Docker Lean Simplification (The "Back to Standard" Plan)

**Created**: 2026-01-18  
**Priority**: P1505 (Critical/High)  
**Status**: Backlog  
**Depends on**: P1503 (Done)

---

## Problem

The current `csb0` Docker setup is over-engineered. It uses a custom Nix-managed directory (`/var/lib/csb0-docker`) with complex symlinks and mixed ownership to separate config from data. This has caused "unsafe path transition" errors, broken Restic mounts, and OCI runtime failures.

## Solution

Pivot to the "Standard Docker Lean" pattern:

1.  **Config**: Run directly from the git repo (`~/Code/nixcfg/hosts/csb0/docker/`) using relative bind mounts for immutable files.
2.  **Data**: Use **Named Docker Volumes** managed by Docker (stored in `/var/lib/docker/volumes`).
3.  **Infrastructure**: Remove all `tmpfiles.rules` from `configuration.nix` that attempt to manage the Docker structure manually.

## Acceptance Criteria

- [ ] **Docker Compose Refactor**:
  - [ ] Convert `nodered`, `mosquitto`, and `uptime-kuma` to use Named Volumes.
  - [ ] Move `acme.json` from `/var/lib/csb0-docker/traefik/` to `./traefik/acme.json` (gitignored).
- [ ] **NixOS Cleanup**:
  - [ ] Remove `systemd.tmpfiles.rules` related to `csb0-docker` in `hosts/csb0/configuration.nix`.
- [ ] **Host Migration**:
  - [ ] Copy data from `/var/lib/csb0-docker/<service>` into new named volumes (using a temporary bridge container if needed).
  - [ ] Verify `acme.json` has `0600` permissions in the repo path.
- [ ] **Verification**:
  - [ ] Run `docker-upf` and verify all services retain their state (history, sessions).

---

## Side Effects & Risks

- **Data Migration**: Moving data from the host bind-mounts into named volumes requires careful `cp -a` while containers are stopped.
- **Permissions**: `acme.json` MUST be `chmod 600` or Traefik will fail to start.
- **Backups**: Ensure Restic snapshots still cover the `/var/lib/docker/volumes` dataset after the switch (it should, as per `disk-config.zfs.nix`).

---

## 💡 Lessons Learned (FAQ for Future Sessions)

**Q: Why did we move away from bind mounts?**  
A: Bind mounts required NixOS (`tmpfiles`) to manage host directories. Mixed ownership between `root` (Nix/Docker) and `mba` (User/Git) caused "Unsafe Path" errors and OCI mount failures.

**Q: Why are Named Volumes better for this project?**  
A: Docker manages the UIDs and GIDs automatically. Since we already have a dedicated ZFS dataset for `/var/lib/docker/volumes` and Restic backs it up, we get persistence and safety without manual Nix configuration.

**Q: What about config files?**  
A: Keep them as relative bind mounts (e.g., `./traefik/static.yml`). This makes the git repo the "live" config source.

**Q: What happened to the `-1` suffix?**  
A: It is standard for Docker Compose V2. It ensures instance numbers are tracked. We removed `container_name` to allow Compose to manage names consistently.

**Q: Where is the repo on the host?**  
A: `/home/mba/Code/nixcfg/`. This is the single source of truth.

**Q: Is /var/lib/csb0-docker gone?**  
A: It will be after this task. It was a redundant layer that complicated the filesystem logic.
