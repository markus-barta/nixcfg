# Vaultwarden on csb1

Backend for the **JANUS** LLM-vault connector (Janus-Warden). Stores the
small subset of personal credentials that may be read by an LLM under
tag-based allowlist control.

- **Domain:** `vault.barta.cm`
- **Host:** csb1 (Netcup VPS 1000 G11, Vienna)
- **Image:** `vaultwarden/server:1.32.7-alpine` (pinned)
- **Database:** SQLite (built-in, in `vaultwarden_data` volume)
- **Network:** external `csb1_traefik` (shared with main host compose)
- **Updates:** manual via PR + redeploy. Watchtower opt-out.

## Why csb1 (not csb0)

Blast-radius separation. csb0 hosts physical-safety-critical services
(garage door via Telegram bot, MQTT for smart home, Headscale for VPN
mesh control). A misbehaving security-critical app like Vaultwarden
should not be co-located with those. csb1 is the productivity /
sensitive-data host (PPM, Docmost, Paperless) — natural neighbours.

Full rationale: PAIMOS · JANUS · Knowledge → Guideline `architecture-v0`.

## Architectural posture

This is the **first production service on csb1 living in nixcfg git**.
The 15 services currently in `/home/mba/docker/docker-compose.yml` on
the host (PPM, Grafana, Paperless, …) are not yet in git — migration is
tracked by the TODO in `configuration.nix`. This compose leads the
pattern: one subdirectory per service, attached to the host-shared
Traefik network as external.

## Prerequisites

### 1. agenix secret `csb1-vaultwarden-env`

Follow the same pattern as `csb1-ppm-env`. The file must contain:

```env
ADMIN_TOKEN=<random 48+ chars>
```

Generate the token with:

```sh
openssl rand -base64 48
```

Optional (recommended once email is needed for invitations):

```env
SMTP_HOST=...
SMTP_PORT=587
SMTP_FROM=noreply@barta.cm
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_SECURITY=starttls
```

Workflow:

1. Add the encrypted file to nixcfg secrets manifest alongside
   `csb1-ppm-env` (same `publicKeys` set).
2. `agenix -e csb1-vaultwarden-env.age` to populate.
3. `nixos-rebuild switch` on csb1 so the secret decrypts to
   `/run/agenix/csb1-vaultwarden-env` at boot.

### 2. DNS

Point `vault.barta.cm` at csb1's public IP (`152.53.64.166`). Cloudflare
proxy on (matches `cloudflarewarp@file` middleware assumption).

### 3. Volume / backup wiring

The `vaultwarden_data` Docker volume holds the SQLite DB, attachments,
and logs. Confirm `restic-cron-hetzner` on csb1 includes it in the
backup set before going live — or accept ephemeral data and migrate to
fleet backup later.

## Deploy

This compose currently lives in the nixcfg repo only. To actually run
it on csb1 (until full in-git automation lands):

```sh
# from your workstation
scp -P 2222 -r hosts/csb1/docker/vaultwarden mba@cs1.barta.cm:/home/mba/docker/

# on csb1
cd /home/mba/docker/vaultwarden
docker compose pull
docker compose up -d
docker compose logs -f vaultwarden    # watch startup
```

Verify:

```sh
curl -sI https://vault.barta.cm/alive       # should return 200
curl -sI https://vault.barta.cm/admin       # 401 or admin page
```

## First-run setup

1. Visit `https://vault.barta.cm/admin` — paste the `ADMIN_TOKEN` from
   the agenix secret.
2. **Disable signups** (UI confirms `SIGNUPS_ALLOWED=false` from compose).
3. **Invite yourself** as the first user via "Invite User" → check email
   (if SMTP configured) or copy the invitation link from the admin
   panel.
4. Log in at `https://vault.barta.cm/`, finish account setup, enable
   2FA immediately.
5. **Create the JANUS infrastructure** (this is the LLM-side prep, not
   normal Vaultwarden use):
   - Create an **Organization** named e.g. `janus-personal`.
   - Inside it, create a **Collection** named `LLM-Readable`.
   - Create a **dedicated user** `janus-reader@<your-domain>` (invite
     via admin panel).
   - Grant the user **read-only access to ONLY the `LLM-Readable`
     collection** (no other collections, no organization-wide
     permissions).
   - Generate an **API key** for `janus-reader` (Bitwarden UI:
     account → security → keys). Note `client_id` + `client_secret`.
   - These two values become the env vars
     `JANUS_VW_CLIENT_ID` / `JANUS_VW_CLIENT_SECRET` for the
     `janus-mcp` binary on your workstation.

## Marking items as LLM-readable

Inside the `LLM-Readable` collection, each item must additionally bear
a custom field:

```
Name:  llm-ok
Type:  Text
Value: true
```

This is the **soft allowlist** Janus-Warden re-checks on every read.
Even an item placed in `LLM-Readable` by mistake won't be returned to
the LLM without the `llm-ok = true` field.

Why the two layers: PAIMOS · JANUS · Guideline `architecture-v0` §6.

## Updates

1. Bump the `image:` tag in `docker-compose.yml`.
2. Review upstream release notes:
   https://github.com/dani-garcia/vaultwarden/releases
3. Commit the bump + push to nixcfg.
4. Redeploy on csb1: `docker compose pull && docker compose up -d`.
5. Verify with the curl checks above.

Watchtower is explicitly disabled (`watchtower.enable=false` label) so
this is the only path to update.

## Troubleshooting

| Symptom                                        | Likely cause                                                   | Fix                                                                                       |
| ---------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `Bad Request` on every API call                | `DOMAIN` env var doesn't match the URL clients use             | Confirm `DOMAIN=https://vault.barta.cm` matches actual host header reaching the container |
| Client gets random Cloudflare IP in audit logs | `IP_HEADER` not honored                                        | Confirm Cloudflare proxy + `cloudflarewarp@file` middleware are both active               |
| 502 from Traefik                               | Container started before joining `csb1_traefik` network        | `docker compose down && up -d`; verify `traefik.docker.network=csb1_traefik` label        |
| Admin panel returns 404                        | Image too old (admin moved to `/admin` proper at some version) | Bump image tag                                                                            |
| Janus `health()` returns auth error            | API user lost collection grant after a Vaultwarden upgrade     | Re-grant `janus-reader` access to `LLM-Readable`                                          |

## See also

- Janus-Warden architecture: PAIMOS · JANUS · Guideline `architecture-v0`
- Token rotation procedure: PAIMOS · JANUS · Runbook `token-rotation`
- Tracking epic: INSPR-180
- Source repo: https://github.com/markus-barta/janus
