# docker-compose-strategy

**Host**: Infrastructure-wide (hsb1, csb0, csb1, hsb8, miniserver-bp)
**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-20

---

## Problem

Across the infrastructure, there is no unified strategy for deploying and managing `docker-compose.yml` files and their associated container data alongside the NixOS configuration.

During the `opus-stream-to-mqtt` investigation, it became apparent that different hosts handle this in fundamentally different ways:

- **hsb1**: The user manually symlinks `~/docker/docker-compose.yml` to the `nixcfg` repository (`/home/mba/Code/nixcfg/hosts/hsb1/docker/docker-compose.yml`). This explicitly separates "managed config" from "unmanaged data" but relies on a manual user action during provisioning.
- **csb0 / csb1 / hsb8**: The `docker-compose.yml` files are deployed (or manually placed) directly in `~/docker/`.
- **miniserver-bp / hsb0**: Use a mix of `virtualisation.oci-containers` (native NixOS) and external/legacy compose setups.

**Critical Question:** We do not yet know how we actually _want_ this to be across the fleet.

- Should we use manual symlinks everywhere (like `hsb1`)?
- Should NixOS automatically generate the symlinks (or copy the files) to `~/docker/` during activation (`environment.etc` / `activationScripts`)?
- Should we separate the compose files entirely from the `nixcfg` repo?
- Should we migrate everything to native NixOS `virtualisation.oci-containers`?

## Solution

Conduct an architectural review of Docker Compose management across the NixOS infrastructure and define a single, unified "NixFleet standard" for deploying containers that are not yet natively packaged in Nix.

## Implementation

- [ ] Audit all current Docker Compose deployments across the fleet.
- [ ] Evaluate the pros/cons of the `hsb1` "manual symlink" method vs automated NixOS placement vs `oci-containers`.
- [ ] Document the chosen strategy in `docs/AGENT-WORKFLOW.md` and `docs/INFRASTRUCTURE.md`.
- [ ] Create host-specific backlog items to migrate each host to the new standard.
- [ ] Update all host `RUNBOOK.md` files to reflect the unified standard.

## Acceptance Criteria

- [ ] A clear, documented standard exists for deploying `docker-compose.yml` within the `nixcfg` repository.
- [ ] The strategy explicitly addresses how to handle unmanaged container data mounts vs version-controlled configuration.
- [ ] Migration tasks are queued for all non-compliant hosts.

## Notes

- This is an architectural decision that impacts how we back up, deploy, and manage stateful services across the entire fleet.
