#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${repo}/hosts/csb1/configuration.nix"
compose="${repo}/hosts/csb1/docker/compose-spec.nix"
init_role="${repo}/hosts/csb1/docker/hausv-postgres/init-application-role.sh"
backup="${repo}/hosts/csb1/docker/restic-cron/hetzner/run_backup.sh"
drill="${repo}/hosts/csb1/scripts/hausv-postgres-restore-drill.sh"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"
secrets="${repo}/secrets/secrets.nix"

nix-instantiate --parse "${host}" >/dev/null
nix-instantiate --parse "${compose}" >/dev/null
bash -n "${drill}"
sh -n "${init_role}"

grep -Fq 'hausv-postgres = {' "${compose}"
grep -Fq '"hausv_postgres_data:/var/lib/postgresql/data"' "${compose}"
grep -Fq '"POSTGRES_PASSWORD_FILE=/run/secrets/hausv-postgres-admin-password"' "${compose}"
# NIX-369: the projections must be owned by the numeric uid the postgres image
# runs as. A supplementary group does NOT survive the entrypoint's gosu
# privilege drop, so a group-readable secret is unreadable by the server
# process — which is exactly how this broke the first time. Assert the
# ownership form directly, and assert the discarded mechanism has not returned.
if [ "$(grep -c 'owner = "70";' "${host}")" -lt 2 ]; then
  echo 'FAIL: both hausv-postgres secret projections must be owned by uid 70' >&2
  exit 1
fi
if sed -n '/hausv-postgres = {/,/^    };/p' "${compose}" | grep -Fq 'group_add'; then
  echo 'FAIL: hausv-postgres must not use group_add; gosu discards supplementary groups' >&2
  exit 1
fi
if grep -Fq 'hausv-postgres-secrets' "${host}"; then
  echo 'FAIL: the hausv-postgres-secrets group was reintroduced; own the projection by uid instead' >&2
  exit 1
fi
grep -Fq '"hausv-egress"' "${compose}"
grep -Fq 'hausv_postgres_data = { };' "${compose}"
grep -Fq 'NOT rolsuper AND NOT rolbypassrls' "${compose}"
grep -Fq '"traefik.enable=false"' "${compose}"

if sed -n '/hausv-postgres = {/,/^    };/p' "${compose}" | grep -Eq 'ports =|profiles ='; then
  echo 'FAIL: HAUSV PostgreSQL must start normally without publishing a host port' >&2
  exit 1
fi

grep -Fq 'NOSUPERUSER' "${init_role}"
grep -Fq 'NOBYPASSRLS' "${init_role}"
grep -Fq "pg_read_file('/run/secrets/hausv-postgres-app-password')" "${init_role}"
if grep -E 'hausv_app.*(SUPERUSER|BYPASSRLS)' "${init_role}" | grep -Ev 'NOSUPERUSER|NOBYPASSRLS'; then
  echo 'FAIL: HAUSV application role may not receive RLS-bypass privileges' >&2
  exit 1
fi

grep -Fq 'age.secrets.csb1-hausv-postgres-admin-password' "${host}"
grep -Fq 'age.secrets.csb1-hausv-postgres-app-password' "${host}"
grep -Fq '"csb1-hausv-postgres-admin-password.age".publicKeys = markus ++ csb1;' "${secrets}"
grep -Fq '"csb1-hausv-postgres-app-password.age".publicKeys = markus ++ csb1;' "${secrets}"

grep -Fq 'systemd.services.hausv-postgres-backup-snapshot = {' "${host}"
grep -Fq 'OnCalendar = "*-*-* 01:10:00";' "${host}"
grep -Fq 'pg_dump --username=postgres --dbname=hausv --format=custom' "${host}"
grep -Fq 'pg_restore --list' "${host}"
grep -Fq '/var/lib/csb1-docker/hausv-postgres-backup-snapshot' "${host}"
grep -Fq -- "--exclude '/backup/var/lib/csb1-docker/hausv-org'" "${backup}"

# The live SQLite/blob path is deliberately unchanged and remains independently
# protected by its original snapshot script and timer.
grep -Fq 'hausvBackupSnapshot = pkgs.writeShellScript "hausv-backup-snapshot"' "${host}"
grep -Fq 'source_dir=/var/lib/csb1-docker/hausv-org' "${host}"
grep -Fq 'PRAGMA integrity_check;' "${host}"
grep -Fq 'OnCalendar = "*-*-* 01:20:00";' "${host}"

grep -Fq 'Phase-2 migration gate — CLOSED' "${runbook}"
grep -Fq 'combined off-site drill' "${runbook}"
grep -Fq 'pg_restore --username=postgres' "${drill}"
grep -Fq -- '--role=hausv_app' "${drill}"
grep -Fq 'false|false' "${drill}"

echo 'T40 HAUSV PostgreSQL Phase-0 contract OK'
