# connect-merlin-gogcli-google-auth

**Host**: hsb0
**Priority**: P50
**Status**: Backlog
**Created**: 2026-03-07

---

## Problem

Merlin (OpenClaw agent on hsb0) needs to be authorized with gogcli to access `markus@barta.com` Google Workspace (calendar, drive, gmail, contacts, sheets, docs) — same as Percy is authorized for `percy.ai@bytepoets.com`.

Multiple auth attempts failed. Token never persisted after `gog auth add --remote`.

## Known Issues / Discoveries

- `GOG_CONFIG_DIR` env var is ignored by gog — tokens always go to `/home/node/.config/gogcli/`
- `credentials.json` must be in Google installed-app format: `{"installed": {"client_id": ..., "client_secret": ..., "redirect_uris": [...], ...}}` — fixed and persisted to host volume
- `gog auth add --remote` flow: prints auth URL → browser OAuth → copy redirect URL from address bar → paste as `--step 2 --auth-url`
- After OAuth completes browser shows "connection refused" on redirect — this is expected (no local server), but `gog auth add --remote --step 2` must be run **in the same shell session** with env sourced
- `state_reused true` warning = stale state file in `/home/node/.config/gogcli/` — delete before retrying
- Auth reports "authorized as markus.barta@gmail.com, expected markus@barta.com" — this is cosmetic, the underlying Gmail address is correct
- Token was never written to keyring despite "success" messages — root cause unclear

## Solution

Run `gog auth add --remote` inside the container with env sourced, complete OAuth in browser, run step 2 in the **same shell**, verify with `gog auth list`.

## Implementation

- [ ] SSH into hsb0, `docker exec -it openclaw-gateway bash`
- [ ] `. /home/node/.config/merlin/gogcli/gogcli.env`
- [ ] `rm -f /home/node/.config/gogcli/oauth-manual-state-*.json`
- [ ] `gog auth add markus@barta.com --services calendar,drive,gmail,contacts,sheets,docs --remote`
- [ ] Open auth URL in browser, sign in as markus@barta.com, copy redirect URL
- [ ] In **same shell**: `gog auth add markus@barta.com --remote --step 2 --auth-url "REDIRECT_URL"`
- [ ] Verify: `gog auth list`
- [ ] Test: `gog gmail list inbox --limit 1`
- [ ] Persist token to merlin volume (copy keyring to `/home/node/.config/merlin/gogcli/keyring/`)
- [ ] Update OPENCLAW-RUNBOOK.md

## Acceptance Criteria

- [ ] `gog auth list` shows `markus@barta.com`
- [ ] `gog gmail list inbox --limit 1` returns results
- [ ] Token survives container restart (persisted to host volume)

## Notes

- Percy reference: `mba-mbp-work` / `mba-imac-work`, authorized for `percy.ai@bytepoets.com`
- Keyring password is in agenix secret, injected via `gogcli.env` as `GOGCLI_KEYRING_PASSWORD`
- entrypoint.sh strips `GOG_KEYRING_PASSWORD=` prefix from secret — fixed in commit `15757e84`
