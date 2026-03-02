# Rotate OpenClaw GitHub PATs

**Priority**: P70
**Status**: Backlog
**Created**: 2026-03-02

---

## Problem

GitHub PATs for `@merlin-ai-mba` and `@nimue-ai-mai` were exposed in `crontab -l`
output during a diagnostic session. The crontab embedded PATs as inline env vars.

Root cause fixed in `b1ef7d9e` — crontab now sources from chmod 600 env file.
Low risk: session data not used for training, no third-party exposure.

## Solution

Rotate both PATs on GitHub, update agenix secrets, deploy.

## Implementation

- [ ] Rotate `@merlin-ai-mba` PAT on GitHub (scope: `repo`)
- [ ] `agenix -e secrets/hsb0-openclaw-github-pat.age` (new value)
- [ ] Rotate `@nimue-ai-mai` PAT on GitHub (scope: `repo`)
- [ ] `agenix -e secrets/hsb0-nimue-github-pat.age` (new value)
- [ ] Commit + push .age files
- [ ] On hsb0: `gitpl && just switch && just oc-rebuild`
- [ ] Verify: workspace push still works for both agents

## Acceptance Criteria

- [ ] Both agents can `git push` to their workspace repos
- [ ] Old PATs are revoked on GitHub

## Notes

Percy's PAT (`@bytepoets-percyai`) was not exposed — no action needed for miniserver-bp.
