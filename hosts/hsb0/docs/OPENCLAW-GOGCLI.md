# OpenClaw gogcli Notes

**Host**: hsb0  
**Agent**: Merlin  
**Backlog item**: `hosts/hsb0/docs/backlog/P50--43dc3b5--connect-merlin-gogcli-google-auth.md`

---

## Current Goal

Authorize Merlin against his own Google account: `merlin.ai.markus@gmail.com`.

Markus-account access is intentionally deferred until Merlin's dedicated account works.

## Which Google Console?

For `merlin.ai.markus@gmail.com`, use **Google Cloud Console / Google Auth Platform**.

Do **not** start in Google Workspace Admin Console unless you later move Merlin to a Workspace-managed account. A plain `gmail.com` account has no Admin Console.

## Fresh Start After Secret Exposure

- rotate `secrets/hsb0-gogcli-keyring-password.age` before continuing
- treat any old gog keyring data as untrusted; recreate auth from scratch
- if you already downloaded an OAuth client JSON to an unsafe place, delete it and download/store a fresh copy securely
- the old Google Cloud project created during failed setup was deleted; setup now starts from zero with Merlin's own account

## Google-Side Setup

### 1. Sign in as Merlin

- log in to `https://console.cloud.google.com/` as `merlin.ai.markus@gmail.com`
- create a dedicated project, e.g. `openclaw-merlin-gogcli`

### 2. Configure Branding

Google Auth Platform -> Branding:

- app name: `OpenClaw Merlin`
- user support email: `merlin.ai.markus@gmail.com`
- developer contact email: Markus or Merlin mailbox you actively monitor
- logo/homepage/privacy-policy/terms: optional for private use; required later if you ever pursue verification

### 3. Configure Audience

Google Auth Platform -> Audience:

- user type: `External`
- recommended publishing status: `In production`

Why: gog requests Gmail and Drive scopes. In `Testing`, Google expires test-user grants after 7 days. That is bad for a persistent agent.

Expected in `In production` without verification: unverified-app warning during consent. For a single private account, that is acceptable.

If you deliberately stay in `Testing` for initial experiments:

- add `merlin.ai.markus@gmail.com` as a test user
- expect refresh tokens to expire after 7 days

### 4. Enable APIs

Enable these APIs in Google Cloud:

- Gmail API
- Google Calendar API
- Google Drive API
- Google Docs API
- Google Sheets API
- People API

### 5. Create OAuth Client

Google Auth Platform -> Clients:

- create client
- application type: `Desktop app`
- name: `OpenClaw Merlin Desktop`
- download the client JSON immediately

Store the JSON outside git and outside the repo, e.g. in Downloads temporarily, then move it into 1Password or another secure store.

### 6. Optional: Data Access Page

Google Auth Platform -> Data Access:

- for private one-account use, you can keep this minimal and let the OAuth flow reveal any missing scope registration
- if Google blocks consent due to missing scopes, add the scopes requested by gog for Gmail, Calendar, Drive, Docs, Sheets, and Contacts

## Minimum Human Checklist

Before touching hsb0 again, Merlin should have:

- a Google Cloud project
- `External` audience
- `In production` publishing status preferred
- required APIs enabled
- a Desktop OAuth client JSON downloaded and stored securely

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
- use `merlin.ai.markus@gmail.com` consistently in auth commands

## GitHub PAT Status

Merlin's GitHub PAT is intentionally removed for now.

Current impact:

- Merlin workspace auto-pull is disabled
- Merlin workspace auto-push is disabled
- `just merlin-pull-workspace` prints a disabled message until a replacement PAT is added
- Nimue is unaffected

Shared workspace bootstrapping falls back to any available agent PAT. That keeps shared repo access working when possible, but Merlin's own personal workspace sync remains disabled until a new Merlin PAT is configured.

- repeat the same auth flags on the final `--auth-code` command
- after successful auth, copy the token into Merlin's persistent config dir

## Persistence Note

After token creation, persist it manually until entrypoint automation exists:

```bash
cp -r /home/node/.config/gogcli/keyring/ /home/node/.config/merlin/gogcli/keyring/
```

This makes the token survive container rebuilds because `/home/node/.config/merlin/gogcli/` is backed by `/var/lib/openclaw-gateway/merlin-gogcli/`.

## Deferred

- whether Merlin should also access `markus@barta.com`, or whether Markus should share specific calendars/docs with Merlin's own Google account instead
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
