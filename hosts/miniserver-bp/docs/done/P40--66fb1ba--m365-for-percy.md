# M365 CLI for Percy (Email + Microsoft 365)

**Host**: miniserver-bp
**Priority**: P40
**Status**: Done (Telegram test pending)
**Created**: 2026-02-13
**Updated**: 2026-02-13

---

## Problem

Percy (Percaival) on miniserver-bp needs email + M365 access. MFA will be mandatory soon, so IMAP password auth won't work long-term.

## Solution

Use `@pnp/cli-microsoft365` (npm) with **client secret auth** (fully headless, no browser needed). Dedicated Azure AD app `Percy-AI-miniserver-bp`.

## Implementation

### Phase 1: Dockerfile + secrets setup

- [x] Add `@pnp/cli-microsoft365` to Dockerfile
- [x] Create dedicated Azure AD app `Percy-AI-miniserver-bp` (Mail.Read + Mail.Send)
- [x] Create agenix secrets with Percy-specific credentials
- [x] Mount secrets in container (`/run/secrets/m365-*:ro`, mode 444)

### Phase 2: Build + deploy

- [x] Commit + push
- [x] Pull + rebuild on server
- [x] Restart container

### Phase 3: Login + verify

- [x] M365 login — `connectedAs: Percy-AI-miniserver-bp`
- [x] Read inbox — 4 messages returned
- [x] Send email — test received by markus.barta@bytepoets.com

### Phase 4: OpenClaw skill

- [x] Custom `m365-email` skill installed in workspace
- [ ] Test via Telegram (ask Percy to read/send email)

### Phase 5: Cleanup

- [x] Removed shared Merlin Azure AD app (`Merlin-AI-hsb1`) from Entra ID
- [x] Removed hsb1 M365 `.age` files + references from secrets.nix + configuration.nix
- [x] Removed himalaya from Dockerfile + config
- [x] Updated docs (RUNBOOK, README, pickup doc)

### Phase 6: Security hardening

- [x] Exchange transport rule: `Block percy.ai external sends` (Enforce, High, Priority 1)

## Acceptance Criteria

- [x] `m365 login` succeeds with client secret auth (headless)
- [x] Percy can list emails via `m365 outlook message list`
- [x] Percy can send emails via `m365 outlook mail send`
- [x] No plain text secrets in config (all via agenix + mounted files)
- [x] Dedicated Azure AD app (not shared with Merlin)
- [x] README.md + RUNBOOK.md updated
- [x] Exchange transport rule blocks external sends

## Notes

- **Why cli-microsoft365?** Headless client secret auth. MFA-proof. Node.js already in container.
- **Why not himalaya?** Pre-built binary lacks OAuth2 cargo feature.
- **Auth**: `--authType secret` = client credentials grant = fully headless
- **Identity**: `percy.ai@bytepoets.com`

## References

- CLI: https://github.com/pnp/cli-microsoft365
- Docs: https://pnp.github.io/cli-microsoft365
- Auth guide: https://pnp.github.io/cli-microsoft365/user-guide/using-own-identity/
