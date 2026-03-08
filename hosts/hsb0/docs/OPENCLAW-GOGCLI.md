# OpenClaw gogcli Notes

**Host**: hsb0  
**Agent**: Merlin  
**Backlog item**: `hosts/hsb0/docs/backlog/P50--43dc3b5--connect-merlin-gogcli-google-auth.md`

---

## Current Goal

Authorize Merlin against his own Google account: `merlin.ai.mba@gmail.com`.

Markus-account access is intentionally deferred until Merlin's dedicated account works.

## Known Good Facts

- gog version in container: `v0.11.0 (91c4c15 2026-02-15)`
- `GOG_CONFIG_DIR` is ignored by gogcli; config resolves to `/home/node/.config/gogcli/`
- `credentials.json` must be installed-app format: `{"installed": {...}}`
- `GOG_KEYRING_BACKEND=file` and `GOG_KEYRING_PASSWORD` are the correct env vars
- gog writes the live token to `/home/node/.config/gogcli/keyring/`
- Merlin's persistent host-mounted path is `/home/node/.config/merlin/gogcli/`

## Known Traps

- `--remote --step 2` is broken in this version with `manual auth state mismatch`
- `--auth-code` is the working workaround for headless auth
- gog requires the exact authorized email address; alias mismatches fail before token persistence
- `keyring_dir` is not a supported gogcli config key; do not try to fix this in `config.json`
- token persistence is split: gog writes to transient `~/.config/gogcli/keyring`, not Merlin's mounted config dir

## Recommended Auth Flow

Use the runbook procedure in `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`.

Key rules:

- source Merlin env first: `. /home/node/.config/merlin/gogcli/gogcli.env`
- use `merlin.ai.mba@gmail.com` consistently in auth commands
- repeat the same auth flags on the final `--auth-code` command
- after successful auth, copy the token into Merlin's persistent config dir

## Persistence Note

After token creation, persist it manually until entrypoint automation exists:

```bash
cp -r /home/node/.config/gogcli/keyring/ /home/node/.config/merlin/gogcli/keyring/
```

This makes the token survive container rebuilds because `/home/node/.config/merlin/gogcli/` is backed by `/var/lib/openclaw-gateway/merlin-gogcli/`.

## Deferred

- whether Merlin should also access `markus@barta.com`
- whether entrypoint should symlink gog's transient config paths into Merlin's mounted config dir

## Relevant Files

| File                                               | Notes                                         |
| -------------------------------------------------- | --------------------------------------------- |
| `hosts/hsb0/docker/openclaw-gateway/entrypoint.sh` | Writes Merlin gog env including `GOG_ACCOUNT` |
| `hosts/hsb0/docker/openclaw-gateway/Dockerfile`    | Bakes gog into the image                      |
| `hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`              | Canonical auth procedure                      |
| `/home/node/.config/gogcli/`                       | Transient gog runtime config                  |
| `/home/node/.config/merlin/gogcli/`                | Merlin persistent config mount                |
| `/var/lib/openclaw-gateway/merlin-gogcli/`         | Host-side persistent volume                   |
