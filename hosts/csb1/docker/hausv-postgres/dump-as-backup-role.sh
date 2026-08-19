#!/bin/sh
set -eu
umask 077

passfile=/run/secrets/hausv-postgres-backup-password
[ -s "$passfile" ] || {
  echo "HAUSV PostgreSQL backup password is missing" >&2
  exit 1
}

pgpass=$(mktemp)
trap 'rm -f "$pgpass"' EXIT
{
  printf '*:*:hausv:hausv_backup:'
  tr -d '\r\n' <"$passfile"
  printf '\n'
} >"$pgpass"
chmod 0600 "$pgpass"

PGPASSFILE=$pgpass pg_dump --username=hausv_backup --dbname=hausv --format=custom \
  --compress=9 --no-owner --no-privileges
