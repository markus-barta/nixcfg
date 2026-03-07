# connect-merlin-gogcli-google-auth

**Host**: hsb0
**Priority**: P50
**Status**: In Progress
**Created**: 2026-03-07

---

## Problem

Merlin (OpenClaw agent on hsb0) needs to be authorized with gogcli to access `markus@barta.com` Google Workspace (calendar, drive, gmail, contacts, sheets, docs) — same as Percy is authorized for `percy.ai@bytepoets.com`.

Multiple auth attempts failed. Token never persisted after `gog auth add --remote`.

## Known Issues / Discoveries

- `GOG_CONFIG_DIR` env var is **ignored** by gog — config always goes to `/home/node/.config/gogcli/`
- `credentials.json` must be Google installed-app format: `{"installed": {...}}` — already correct and persisted to host volume
- **Account must be `markus.barta@gmail.com`** (not `markus@barta.com`) — gog rejects the Workspace alias. "authorized as markus.barta@gmail.com, expected markus@barta.com" is cosmetic only.
- **`--remote --step 2` has a confirmed bug**: `manual auth state mismatch` occurs every time regardless of shell, quoting, timing, or email. State file IS written, state hash DOES match, but gog still rejects it. Root cause unknown — likely gog v0.11.0 bug.
- **Workaround**: `--auth-code` flag exists in the binary (hidden, undocumented): `"UNSAFE: Authorization code from browser (manual flow; skips state check; not valid with --remote)"` — bypasses state check entirely.
- SSH tunnel required for OAuth callback (hsb0 has no browser). Port is random each run — get it from step 1 output, then tunnel that port.
- Correct tunnel: `ssh -L PORT:127.0.0.1:PORT mba@hsb0.lan`
- Stale state files must be deleted before each attempt: `rm -f /home/node/.config/gogcli/oauth-manual-state-*.json`
- Keyring dir exists but is empty: `/home/node/.config/merlin/gogcli/keyring/` — token never yet persisted.

## Solution

Use `--auth-code` flag (bypasses broken `--step 2` state check). See OPENCLAW-RUNBOOK.md → "gogcli Auth" for the full procedure.

## Implementation

- [x] Confirm container running (`openclaw-gateway`, up on hsb0)
- [x] Confirm `credentials.json` and `gogcli.env` present and correct
- [x] Identify root cause: `--remote --step 2` state mismatch bug + wrong email
- [x] Find `--auth-code` workaround (inspected gog binary strings)
- [ ] Complete interactive OAuth auth (requires human in the loop — browser)
- [ ] Verify: `gog auth list` shows `markus@barta.com`
- [ ] Test: `gog gmail list inbox --limit 1` returns results
- [ ] Persist token to host volume (`/home/node/.config/merlin/gogcli/keyring/`)
- [ ] Update status to Done
- [ ] Update OPENCLAW-RUNBOOK.md status table (Google gogcli → ✅ Working)

## Acceptance Criteria

- [ ] `gog auth list` shows `markus@barta.com`
- [ ] `gog gmail list inbox --limit 1` returns results
- [ ] Token survives container restart (persisted to host volume)

## Notes

- Percy reference: `mba-mbp-work` / `mba-imac-work`, authorized for `percy.ai@bytepoets.com`
- Keyring password is in agenix secret, injected via `gogcli.env` as `GOGCLI_KEYRING_PASSWORD`
- entrypoint.sh strips `GOG_KEYRING_PASSWORD=` prefix from secret — fixed in commit `15757e84`
- gog version: `v0.11.0 (91c4c15 2026-02-15)`
