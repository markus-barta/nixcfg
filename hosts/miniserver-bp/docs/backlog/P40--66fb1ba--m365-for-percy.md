# M365 CLI for Percy (Email + Microsoft 365)

**Host**: miniserver-bp
**Priority**: P40
**Status**: In Progress
**Created**: 2026-02-13
**Updated**: 2026-02-13

---

## Problem

Percy (Percaival) on miniserver-bp needs email + M365 access. MFA will be mandatory soon, so IMAP password auth won't work long-term.

## Solution

Use `@pnp/cli-microsoft365` (npm) with **client secret auth** (fully headless, no browser needed). Reuse existing Azure AD app from hsb1.

## Implementation

### Phase 1: Dockerfile + secrets setup

- [ ] Add `@pnp/cli-microsoft365` to Dockerfile: `npm install -g @pnp/cli-microsoft365`
- [ ] Add agenix secrets to `secrets/secrets.nix`:
  - `miniserver-bp-m365-client-id.age`
  - `miniserver-bp-m365-tenant-id.age`
  - `miniserver-bp-m365-client-secret.age`
- [ ] Create `.age` files (same values as hsb1 Azure app):
  ```bash
  agenix -e secrets/miniserver-bp-m365-client-id.age
  agenix -e secrets/miniserver-bp-m365-tenant-id.age
  agenix -e secrets/miniserver-bp-m365-client-secret.age
  ```
- [ ] Add agenix declarations to `configuration.nix`
- [ ] Mount secrets as files in container (`/run/secrets/m365-*:ro`)

### Phase 2: Build + deploy

- [ ] Commit + push
- [ ] Pull on server
- [ ] `sudo nixos-rebuild switch --flake .#miniserver-bp`
- [ ] Rebuild Docker image: `docker build -t openclaw-percaival:latest . --no-cache`
- [ ] Restart container: `sudo systemctl restart docker-openclaw-percaival`

### Phase 3: Login + verify

- [ ] Login from inside container:
  ```bash
  docker exec -it openclaw-percaival sh -c \
    'm365 login --authType secret \
      --appId "$(cat /run/secrets/m365-client-id)" \
      --tenant "$(cat /run/secrets/m365-tenant-id)" \
      --secret "$(cat /run/secrets/m365-client-secret)"'
  ```
- [ ] Test email: `docker exec openclaw-percaival m365 outlook mail list`
- [ ] Test send: `docker exec openclaw-percaival m365 outlook mail send --to "markus@barta.com" --subject "Test from Percy" --bodyContents "Hello from miniserver-bp"`

### Phase 4: OpenClaw skill

- [ ] Write or install an OpenClaw skill that wraps `m365` commands
- [ ] Test via Telegram: ask Percy to read/send email

## Acceptance Criteria

- [ ] `m365 login` succeeds with client secret auth (headless)
- [ ] Percy can list emails via `m365 outlook mail list`
- [ ] Percy can send emails via `m365 outlook mail send`
- [ ] No plain text secrets in config (all via agenix + mounted files)
- [ ] README.md + RUNBOOK.md updated

## Notes

- **Why cli-microsoft365?** Supports headless client secret auth (no browser). MFA-proof. Node.js already in container. Broader than just email (Teams, Calendar, etc.)
- **Why not himalaya?** Pre-built binary doesn't include `oauth2` cargo feature. Would need building from source.
- **himalaya stays installed** for IMAP fallback (password auth configured via wizard)
- **Azure AD app**: Same app registration as hsb1 (reuse client-id/secret/tenant-id)
- **Auth method**: `--authType secret` = client credentials grant = fully headless

## References

- CLI: https://github.com/pnp/cli-microsoft365
- Docs: https://pnp.github.io/cli-microsoft365
- Auth guide: https://pnp.github.io/cli-microsoft365/user-guide/using-own-identity/
- hsb1 secrets pattern: `secrets/hsb1-openclaw-m365-*.age`
