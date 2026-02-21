# nimue-dedicated-email

**Host**: hsb0
**Priority**: P70
**Status**: Backlog
**Created**: 2026-02-21

---

## Problem

Nimue's GitHub account (`@nimue-ai-mai`) uses `mailina.barta@gmail.com` as its primary email.
This means account recovery and GitHub notifications land in Mailina's personal inbox, which
is not ideal for separation of concerns.

## Solution

Create a dedicated Gmail account for Nimue (e.g. `nimue.ai.mai@gmail.com`) and update
the GitHub account's primary email to it.

## Implementation

- [ ] Create Gmail account `nimue.ai.mai@gmail.com` (or similar)
- [ ] Log into `@nimue-ai-mai` GitHub → Settings → Emails → update primary email
- [ ] Verify email on GitHub
- [ ] Store credentials in 1Password

## Acceptance Criteria

- [ ] `@nimue-ai-mai` GitHub primary email is NOT `mailina.barta@gmail.com`
- [ ] New email is verified on GitHub

## Notes

- No changes needed to nixcfg, entrypoint.sh, or agenix secrets
- The noreply git email (`262988279+nimue-ai-mai@users.noreply.github.com`) stays the same
- Low priority — purely administrative, nothing breaks without this
