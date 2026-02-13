# ! PICKUP — M365 CLI for Percy (miniserver-bp)

**Last session**: 2026-02-13
**Backlog item**: `hosts/miniserver-bp/docs/backlog/P40--66fb1ba--m365-for-percy.md`

---

## Current State

- [x] `@pnp/cli-microsoft365` added to Dockerfile + image rebuilt
- [x] Agenix secrets created (copied from hsb1 Azure app + rekeyed)
- [x] Secrets mounted in container at `/run/secrets/m365-*`
- [x] Permission fix pushed (mode 444) — **NOT YET APPLIED on server**
- [x] himalaya removed from Dockerfile + config
- [x] cvsloane/m365-skill removed from docs

## Next Steps (in order)

1. **Pull + NixOS rebuild** on miniserver-bp (for secret permissions fix):

   ```bash
   cd ~/Code/nixcfg && git pull
   sudo nixos-rebuild switch --flake .#miniserver-bp
   ```

2. **Restart container** (picks up new secret mounts):

   ```bash
   sudo systemctl restart docker-openclaw-percaival
   ```

3. **Login to M365**:

   ```bash
   docker exec -it openclaw-percaival sh -c \
     'm365 login --authType secret \
       --appId "$(cat /run/secrets/m365-client-id)" \
       --tenant "$(cat /run/secrets/m365-tenant-id)" \
       --secret "$(cat /run/secrets/m365-client-secret)"'
   ```

4. **Test email**:

   ```bash
   docker exec openclaw-percaival m365 outlook mail list
   ```

5. **If login works**: Create/install OpenClaw skill wrapping `m365` commands

6. **Update docs**: README.md, RUNBOOK.md, mark backlog done

## Key Files Changed

| File                                                | Change                                           |
| --------------------------------------------------- | ------------------------------------------------ |
| `hosts/miniserver-bp/docker/Dockerfile`             | Added m365 cli, removed himalaya                 |
| `hosts/miniserver-bp/configuration.nix`             | M365 secrets (mode 444), removed himalaya volume |
| `secrets/secrets.nix`                               | 3 new secrets (miniserver-bp-m365-\*)            |
| `secrets/miniserver-bp-m365-*.age`                  | Copied from hsb1 + rekeyed                       |
| `hosts/miniserver-bp/docs/OPENCLAW-DOCKER-SETUP.md` | Replaced himalaya with m365 cli                  |

## Context

- Azure AD app is shared with hsb1 (same client-id/secret/tenant-id)
- Auth method: `--authType secret` = client credentials grant = fully headless
- himalaya was tried first but pre-built binary lacks OAuth2 cargo feature
- Percy's email: `percy.ai@bytepoets.com`
