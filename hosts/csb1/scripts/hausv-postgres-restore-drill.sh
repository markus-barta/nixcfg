#!/usr/bin/env bash
set -euo pipefail

container=${HAUSV_POSTGRES_CONTAINER:-hausv-postgres}
dump=${1:-/var/lib/csb1-docker/hausv-postgres-backup-snapshot/hausv.dump}
drill_db="hausv_restore_drill_$(date -u +%Y%m%d%H%M%S)_$$"

case "$drill_db" in
hausv_restore_drill_[0-9]*) ;;
*)
  echo "unsafe restore-drill database name" >&2
  exit 1
  ;;
esac
[ -s "$dump" ] || {
  echo "recovery-point dump is missing or empty" >&2
  exit 1
}

cleanup() {
  docker exec --user postgres "$container" \
    dropdb --username=postgres --if-exists --force "$drill_db" >/dev/null
}
trap cleanup EXIT HUP INT TERM

test "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy
docker exec --user postgres "$container" \
  createdb --username=postgres --owner=hausv_app "$drill_db"
docker exec --user postgres -i "$container" \
  pg_restore --username=postgres --dbname="$drill_db" --exit-on-error \
  --single-transaction --no-owner --no-privileges --role=hausv_app <"$dump"

role_flags=$(docker exec --user postgres "$container" \
  psql --username=postgres --dbname="$drill_db" --tuples-only --no-align \
  --command="SELECT rolsuper || '|' || rolbypassrls FROM pg_roles WHERE rolname='hausv_app'")
test "$role_flags" = "false|false"
foreign_owner_count=$(docker exec --user postgres "$container" \
  psql --username=postgres --dbname="$drill_db" --tuples-only --no-align \
  --command="SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_roles r ON r.oid=c.relowner WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast' AND c.relkind IN ('r','p','v','m','S','f') AND r.rolname <> 'hausv_app'")
test "$foreign_owner_count" = "0"
docker exec --user postgres "$container" \
  psql --username=hausv_app --dbname="$drill_db" --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --command='SELECT current_database()' >/dev/null

echo "HAUSV PostgreSQL isolated restore drill: OK"
