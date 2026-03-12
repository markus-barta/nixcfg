# gogcli-credentials-agenix (Percy)

**Host**: miniserver-bp
**Priority**: P50
**Status**: Backlog
**Created**: 2026-03-12

---

## Problem

Percy's `credentials.json` (Google OAuth client registration) is placed manually in
`/var/lib/openclaw-percaival/gogcli/` — not declarative, not reproducible after a fresh host install.

Nimue on hsb0 now handles this declaratively via agenix (implemented 2026-03-12).
Percy should follow the same pattern.

## Solution

Encrypt `credentials.json` as `miniserver-bp-gogcli-credentials.age`, declare in NixOS config,
mount via docker-compose, deploy via entrypoint.

## Implementation

- [ ] `agenix -e secrets/miniserver-bp-gogcli-credentials.age` (paste credentials.json content)
- [ ] Add to `secrets/secrets.nix`: `"miniserver-bp-gogcli-credentials.age".publicKeys = markus ++ miniserver-bp`
- [ ] Add to `hosts/miniserver-bp/configuration.nix`: `age.secrets.miniserver-bp-gogcli-credentials`
- [ ] Add to `docker-compose.yml`: mount `/run/agenix/miniserver-bp-gogcli-credentials:/run/secrets/gogcli-credentials:ro`
- [ ] In entrypoint / activation: copy `/run/secrets/gogcli-credentials` → `/var/lib/openclaw-percaival/gogcli/credentials.json`
- [ ] Deploy: `gitpl && just switch && just percy-rebuild` on miniserver-bp

## Acceptance Criteria

- [ ] `credentials.json` no longer manually placed in host volume
- [ ] gog auth still works after rebuild

## Notes

Reference: Nimue implementation on hsb0 (`hosts/hsb0/docker/openclaw-gateway/entrypoint.sh`)
