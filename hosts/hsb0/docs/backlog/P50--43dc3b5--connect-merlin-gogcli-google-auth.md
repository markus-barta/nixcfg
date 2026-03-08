# connect-merlin-gogcli-google-auth

**Host**: hsb0
**Priority**: P50
**Status**: In Progress
**Created**: 2026-03-07

---

## Problem

Merlin (OpenClaw agent on hsb0) needs to be authorized with gogcli against his dedicated Google account `merlin.ai.markus@gmail.com` for calendar, drive, gmail, contacts, sheets, and docs.

Previous attempts used the wrong target account and an old Google Cloud project that has since been deleted. This work now restarts from scratch for Merlin's own account only.

## Known Issues / Discoveries

- `GOG_CONFIG_DIR` env var is **ignored** by gog — config always goes to `/home/node/.config/gogcli/`
- `credentials.json` must be Google installed-app format: `{"installed": {...}}` — already correct and persisted to host volume
- Merlin's target account is `merlin.ai.markus@gmail.com`
- old Google Cloud project was deleted; assume no reusable Google-side setup remains
- gog requires the exact authorized email; alias mismatches fail before token persistence
- **`--remote --step 2` has a confirmed bug**: `manual auth state mismatch` occurs every time regardless of shell, quoting, timing, or email. State file IS written, state hash DOES match, but gog still rejects it. Root cause unknown — likely gog v0.11.0 bug.
- **Workaround**: `--auth-code` flag exists in the binary (hidden, undocumented): `"UNSAFE: Authorization code from browser (manual flow; skips state check; not valid with --remote)"` — bypasses state check entirely.
- SSH tunnel required for OAuth callback (hsb0 has no browser). Port is random each run — get it from step 1 output, then tunnel that port.
- Correct tunnel: `ssh -L PORT:127.0.0.1:PORT mba@hsb0.lan`
- Stale state files must be deleted before each attempt: `rm -f /home/node/.config/gogcli/oauth-manual-state-*.json`
- `keyring_dir` is not a supported gogcli config key
- Token persistence currently requires copying `/home/node/.config/gogcli/keyring/` into `/home/node/.config/merlin/gogcli/keyring/`

## Solution

Create a fresh Google Cloud / Google Auth Platform setup under `merlin.ai.markus@gmail.com`, then use `--auth-code` (bypasses broken `--step 2` state check), authenticate as `merlin.ai.markus@gmail.com`, and copy the transient keyring into Merlin's persistent config dir. See `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md` and `hosts/hsb0/docs/OPENCLAW-GOGCLI.md`.

## Implementation

- [x] Confirm container running (`openclaw-gateway`, up on hsb0)
- [ ] Create fresh Google Cloud project for `merlin.ai.markus@gmail.com`
- [ ] Create fresh Desktop OAuth client JSON for Merlin
- [ ] Confirm fresh `credentials.json` is installed and `gogcli.env` is correct
- [x] Identify root cause: `--remote --step 2` state mismatch bug + prior wrong target account
- [x] Find `--auth-code` workaround (inspected gog binary strings)
- [ ] Complete interactive OAuth auth for `merlin.ai.markus@gmail.com` (requires human in the loop — browser)
- [ ] Verify: `gog auth list` shows `merlin.ai.markus@gmail.com`
- [ ] Test: `gog gmail list inbox --limit 1` returns results
- [ ] Persist token to host volume (`/home/node/.config/merlin/gogcli/keyring/`)
- [ ] Update status to Done
- [ ] Update OPENCLAW-RUNBOOK.md status table (Google gogcli → ✅ Working)
- [ ] Decide separately whether Merlin should access Markus Google account later, or whether Markus should share selected resources with Merlin instead

## Acceptance Criteria

- [ ] `gog auth list` shows `merlin.ai.markus@gmail.com`
- [ ] `gog gmail list inbox --limit 1` returns results
- [ ] Token survives container restart (persisted to host volume)

## Notes

- Percy reference: `mba-mbp-work` / `mba-imac-work`, authorized for `percy.ai@bytepoets.com`
- Keyring password is in agenix secret, injected via `gogcli.env` as `GOG_KEYRING_PASSWORD`
- entrypoint.sh strips `GOG_KEYRING_PASSWORD=` prefix from secret — fixed in commit `15757e84`
- gog version: `v0.11.0 (91c4c15 2026-02-15)`
- Markus-account access is explicitly out of scope for this backlog item
- There is no separate active backlog item for Markus-account Google access; revisit only after Merlin's own gogcli setup works
