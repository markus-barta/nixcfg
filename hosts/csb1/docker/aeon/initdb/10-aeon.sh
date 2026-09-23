# shellcheck shell=bash
# AEON-12: PAIMOS AEON database bootstrap, sourced once by the postgres entrypoint
# on an empty volume. The app role is NOT a superuser and has no BYPASSRLS, so
# row-level security applies to it (FORCE ROW LEVEL SECURITY on tenant tables).
# The password comes from the host-generated file; it never appears in argv.
aeon_pw="$(cat /run/secrets/aeon-db-password)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres --set=pw="$aeon_pw" <<'SQL'
CREATE ROLE aeon LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'pw';
CREATE DATABASE aeon OWNER aeon;
SQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname aeon <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
unset aeon_pw
