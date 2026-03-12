# gogcli-credentials-agenix (Merlin)

**Host**: hsb0
**Priority**: P50
**Status**: Backlog
**Created**: 2026-03-12

---

## Problem

Merlin's `credentials.json` (Google OAuth client registration) is placed manually in
`/var/lib/openclaw-gateway/merlin-gogcli/` — not declarative, not reproducible after a fresh host install.

Nimue's credentials are already handled declaratively via agenix (implemented 2026-03-12).
Merlin should follow the same pattern.

## Solution

Encrypt `credentials.json` as `hsb0-merlin-gogcli-credentials.age`, declare in NixOS config,
mount via docker-compose, deploy via `init_agent` 8th param (same as Nimue).

## Implementation

- [ ] `agenix -e secrets/hsb0-merlin-gogcli-credentials.age` (paste credentials.json content)
- [ ] Add to `secrets/secrets.nix`: `"hsb0-merlin-gogcli-credentials.age".publicKeys = markus ++ hsb0`
- [ ] Add to `hosts/hsb0/configuration.nix`: `age.secrets.hsb0-merlin-gogcli-credentials`
- [ ] Add to `docker-compose.yml`: mount `/run/agenix/hsb0-merlin-gogcli-credentials:/run/secrets/merlin-gogcli-credentials:ro`
- [ ] Pass `/run/secrets/merlin-gogcli-credentials` as 8th arg to Merlin's `init_agent` call in `entrypoint.sh`
- [ ] Deploy: `gitpl && just switch && just oc-rebuild` on hsb0

## Acceptance Criteria

- [ ] `credentials.json` no longer manually placed in host volume
- [ ] Container boot log shows `[agent:merlin] gogcli credentials.json deployed from agenix`

## Notes

Reference: Nimue implementation in `hosts/hsb0/docker/openclaw-gateway/entrypoint.sh` + `docker-compose.yml`
