#!/bin/sh
set -eu

app_password_file=/run/secrets/hausv-postgres-app-password
[ -s "$app_password_file" ] || {
  echo "HAUSV PostgreSQL application password is missing" >&2
  exit 1
}

# Read the password inside the PostgreSQL server process. This keeps it out of
# command arguments, logs and generated SQL files. The role is deliberately
# separate from the bootstrap superuser: RLS is not a security boundary for a
# role with SUPERUSER or BYPASSRLS.
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 <<'SQL'
DO $bootstrap$
DECLARE
  app_password text := btrim(pg_read_file('/run/secrets/hausv-postgres-app-password'));
BEGIN
  IF app_password = '' THEN
    RAISE EXCEPTION 'HAUSV PostgreSQL application password is empty';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hausv_app') THEN
    EXECUTE format(
      'CREATE ROLE hausv_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
      app_password
    );
  ELSE
    ALTER ROLE hausv_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    EXECUTE format('ALTER ROLE hausv_app PASSWORD %L', app_password);
  END IF;
END
$bootstrap$;

GRANT CONNECT ON DATABASE hausv TO hausv_app;
GRANT USAGE, CREATE ON SCHEMA public TO hausv_app;
SQL
