#!/bin/sh
set -eu

backup_password_file=/run/secrets/hausv-postgres-backup-password
[ -s "$backup_password_file" ] || {
  echo "HAUSV PostgreSQL backup password is missing" >&2
  exit 1
}

# Read the password inside the PostgreSQL server process. This keeps it out of
# command arguments, logs and generated SQL files. hausv_backup is the dump
# role: BYPASSRLS so FORCE ROW LEVEL SECURITY does not break pg_dump, and
# never SUPERUSER.
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 <<'SQL'
DO $bootstrap$
DECLARE
  backup_password text := btrim(pg_read_file('/run/secrets/hausv-postgres-backup-password'));
BEGIN
  IF backup_password = '' THEN
    RAISE EXCEPTION 'HAUSV PostgreSQL backup password is empty';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hausv_backup') THEN
    EXECUTE format(
      'CREATE ROLE hausv_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS PASSWORD %L',
      backup_password
    );
  ELSE
    ALTER ROLE hausv_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS;
    EXECUTE format('ALTER ROLE hausv_backup PASSWORD %L', backup_password);
  END IF;
END
$bootstrap$;

GRANT CONNECT ON DATABASE hausv TO hausv_backup;
GRANT USAGE ON SCHEMA public TO hausv_backup;
REVOKE CREATE ON SCHEMA public FROM hausv_backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO hausv_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO hausv_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE hausv_app IN SCHEMA public GRANT SELECT ON TABLES TO hausv_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE hausv_app IN SCHEMA public GRANT SELECT ON SEQUENCES TO hausv_backup;
SQL
