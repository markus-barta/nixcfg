# PPM on csb1 — Runbook

PPM (the `paimos` codebase, branded as PPM for `pm.barta.cm`) runs as a
single container on csb1, behind Traefik. This runbook covers the day-to-day
operations: deploy, verify, roll back, inspect logs, back up.

**Nothing is built here.** CI (GitHub Actions on `markus-barta/paimos`)
publishes the image to GHCR; csb1 just pulls and runs it.

---

## 1. Facts at a glance

|                                               |                                                                         |
| --------------------------------------------- | ----------------------------------------------------------------------- |
| Service name in `~/docker/docker-compose.yml` | `ppm`                                                                   |
| Container name                                | `ppm`                                                                   |
| Image                                         | `ghcr.io/markus-barta/paimos:latest`                                    |
| Public URL                                    | https://pm.barta.cm                                                     |
| Health endpoint                               | `GET /api/health` → `{"service":"ppm","status":"ok"}`                   |
| Data volume                                   | `csb1_ppm_data` (mounted at `/app/data` — contains SQLite DB `ppm.db`)  |
| Attachment bucket                             | MinIO bucket `ppm-attachments` (separate `minio` service, same compose) |
| TLS + routing                                 | Traefik label `Host(\`pm.barta.cm\`)`, cert via `default` resolver      |
| Secrets                                       | `/run/agenix/csb1-ppm-env` (managed via nix/agenix — see `nixfleet/`)   |
| Source repo                                   | https://github.com/markus-barta/paimos                                  |

---

## 2. Deploy flow — routine

Trigger: a PR has been merged to `main` in the paimos repo. CI has finished
and published a fresh `:latest` to GHCR. You want csb1 to run it.

```bash
ssh mba@csb1
cd ~/docker
docker compose pull ppm
docker compose up -d ppm
```

Or as a one-liner from your laptop:

```bash
ssh mba@csb1 "cd ~/docker && docker compose pull ppm && docker compose up -d ppm"
```

Or via the just recipe:

```bash
ssh mba@csb1 "cd ~/docker && just deploy-ppm"
```

Compose will recreate the `ppm` container with the new image. Existing data
stays (named volume `csb1_ppm_data` survives container replacement).

### Verify after deploy

```bash
# 1. Health
curl -s https://pm.barta.cm/api/health
# → {"service":"ppm","status":"ok"}

# 2. Version in sidebar footer
# Visit https://pm.barta.cm and check the version string — should match the
# git tag from the latest release (CI bakes __APP_VERSION__ at build time
# from the tag; see paimos repo PR #3 for the CI logic).

# 3. Container state
ssh mba@csb1 "docker ps --filter name=ppm --format '{{.Names}}\t{{.Status}}\t{{.Image}}'"
```

---

## 3. Pinning to a specific version (rollback or explicit version)

`:latest` always follows `main`. If you need a known version, edit
`~/docker/docker-compose.yml` and change the `image:` line under `ppm:`:

```yaml
ppm:
  image: ghcr.io/markus-barta/paimos:1.2.0 # was :latest
```

Then pull + up as normal:

```bash
docker compose pull ppm && docker compose up -d ppm
```

**Rollback recipe.** If a `:latest` deploy broke something and you need to
go back to a known-good version:

1. Check what versions exist: https://github.com/markus-barta/paimos/pkgs/container/paimos
2. Pin to the previous release tag, e.g. `:1.1.2` (or the exact SHA-tag
   like `:sha-abc1234` from an older main build).
3. Pull + up.
4. Open a PR to revert the offending change on `main`, then switch back to
   `:latest` once a new known-good image is published.

**Don't** use `docker compose up -d --force-recreate ppm` as a rollback
— it would just restart the same (broken) image. You need a different tag
or image SHA.

---

## 4. Logs & diagnostics

```bash
# Live tail, last 200 lines
ssh mba@csb1 "docker logs -f --tail 200 ppm"

# Since a specific time
ssh mba@csb1 "docker logs --since 30m ppm 2>&1 | less"

# Container stats (CPU/mem)
ssh mba@csb1 "docker stats --no-stream ppm"

# Exec a shell inside (e.g. to poke at SQLite)
ssh mba@csb1 "docker exec -it ppm sh"
# then inside: sqlite3 /app/data/ppm.db '.tables'
```

On first-ever run the app runs all DB migrations and prints each one to
stdout — visible in `docker logs` if anything goes wrong.

---

## 5. Data & backups

- **SQLite DB**: `csb1_ppm_data` volume, file `/app/data/ppm.db`.
- **Attachments**: MinIO bucket `ppm-attachments` (lives in the `minio`
  service, same compose).
- **Backups**: `restic-cron` service handles scheduled off-site backup to
  Hetzner Storage Box. See `~/docker/restic-cron/` for the schedule and
  retention policy.

**Ad-hoc snapshot before a risky deploy:**

```bash
ssh mba@csb1 "docker exec ppm sqlite3 /app/data/ppm.db '.backup /app/data/ppm.pre-deploy.db'"
# Restore: stop container, copy the backup over the main file, start.
```

---

## 6. Environment + secrets

The compose file declares env vars directly (brand identity, DB filename,
bucket name, health service label) plus loads secrets from
`/run/agenix/csb1-ppm-env` (admin password, cookie key, SMTP creds, etc.).

To change a secret:

1. Edit the nix/agenix source in `~/docker/nixfleet/` (the agenix secret
   entry for `csb1-ppm-env`).
2. Rebuild the host config, which refreshes `/run/agenix/csb1-ppm-env`.
3. Restart the container: `docker compose up -d ppm` (compose picks up the
   updated `env_file` on next container creation — for an unchanged image
   you may need `--force-recreate`).

To change a public env var (brand, port, etc.): edit the `environment:`
block in `~/docker/docker-compose.yml`, then `docker compose up -d ppm`.

---

## 7. Troubleshooting

| Symptom                                                    | Likely cause                                               | Action                                                                      |
| ---------------------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------- |
| `/api/health` returns 502 via Traefik                      | Container crashed on startup (usually a migration error)   | `docker logs ppm` — look for migration output; fix root cause, then `up -d` |
| `/api/health` reachable locally but 404 via the public URL | Traefik label changed, or the `traefik` service is down    | `docker ps` + `docker logs traefik`                                         |
| Sidebar version string reads `*-dev+<sha>` on a release    | Image pulled before CI finished, or no `v*` tag was cut    | Check GitHub Actions runs; pull again after success                         |
| "no such service: paimos" on deploy command                | Using wrong service name — it's `ppm`, not `paimos`        | Use `ppm`                                                                   |
| New feature doesn't appear after deploy                    | Browser SPA cache — hard-reload or Shift+Reload            |                                                                             |
| SQLite "database is locked" spam in logs                   | Two processes writing, or backup running during heavy load | Normally self-recovers (5s busy timeout). Investigate if persistent.        |

---

## 8. What NOT to do

- **Don't** build the image on csb1 (`docker compose build ppm`). The
  image is baked in CI with the version-string logic intact; a local
  build would produce an image whose sidebar shows `1.0.0` regardless of
  the actual content. Always `pull`, never `build`, for this service.
- **Don't** delete the `csb1_ppm_data` volume. It holds the SQLite DB — losing
  it wipes every user, issue, comment, and history row.
- **Don't** hand-edit rows in `ppm.db` without taking a snapshot first.
  Migrations are forward-only; a schema mismatch will take the app down.

---

## 9. Related

- Paimos source: https://github.com/markus-barta/paimos
- Deploy CI workflow: `.github/workflows/ci.yml` in the repo (see PR #3
  for the VERSION-sync logic).
- Nix/agenix secret source: `~/docker/nixfleet/` on csb1.

---

## 10. Known gotchas (learned the hard way)

**No `sqlite3` in the `ppm` image.** Runtime container is minimal (Go binary + SPA only). For in-container SQLite work, copy the DB file out to the host and use a sidecar container with `sqlite3` installed (e.g. `docker run --rm -v csb1_ppm_data:/d alpine sh -c "apk add -q sqlite && sqlite3 /d/ppm.db ..."`).

**SQLite WAL mode is live data.** `docker compose stop ppm` does NOT guarantee the write-ahead log (`.db-wal`) has been checkpointed into the main `.db`. Any rename / backup / copy op must treat `ppm.db`, `ppm.db-wal` and `ppm.db-shm` as a set, or explicitly checkpoint first (`PRAGMA wal_checkpoint(TRUNCATE);` while the app is running and writing through it).

- Last observed: 2026-04-20, during the rename from `bp-pm.db` to `ppm.db`. A raw `cp ppm.db` snapshot after `docker compose stop` missed ~4 hours of WAL-only writes (including a freshly-minted API key and several ticket updates). Recovery required minting a new API key via the browser and replaying writes by hand.
- **Correct pattern** for a DB-file rename / backup:

  ```bash
  # 1. Force a checkpoint while the app is live (so main .db is authoritative)
  # NOTE: this requires sqlite3 — not available in the ppm image, so work around
  # by stopping the app and copying ALL THREE files as one snapshot.

  # 2. Stop the app.
  docker compose stop ppm

  # 3. Snapshot all three files, not just .db
  docker run --rm -v csb1_ppm_data:/d -v /home/mba:/out busybox sh -c '
    for f in ppm.db ppm.db-shm ppm.db-wal; do
      [ -e /d/ ] && cp /d/ /out/.snapshot
    done
  '

  # 4. Do the rename — all three at once.
  # 5. Start the app and verify before deleting snapshots.
  ```

**Shell escaping through multiple layers eats `->` in echo.** `echo mv "$f" -> "$new"` gets parsed as `echo mv $f -` redirected to `$new`, overwriting the file you just moved with 17 bytes of text. Never write `->` in shell. If you need a log line, use `echo "moved $f to $new"`. For any rename loop, do the `mv` and the log in separate statements and eyeball the result of each `mv` before moving on.

**The real Docker volume name is project-prefixed.** Compose creates `csb1_ppm_data` (project=`csb1` because the compose file is at `~/docker/` and project name is inherited from parent dir or `COMPOSE_PROJECT_NAME`). Using bare `ppm_data` with `docker run -v` will silently create a NEW empty volume. Always `docker volume ls | grep ppm` to confirm the name before mounting.
