#!/usr/bin/env bash
# OPS-136 P2 — attended cutover. LINEAR and NON-INTERACTIVE: every approval
# happens before this script runs. Run as root inside a persistent tmux
# session (SSH loss must not kill the window):
#
#   tmux new -s ops136
#   /home/mba/Code/nixcfg/hosts/csb1/docker/ops136/cutover.sh <P1-artifacts-dir>
#
# Ordering: everything failable is front-loaded BEFORE the point of no
# return (legacy stop). After it, any failure triggers the scripted rollback
# automatically. The flock is held by this process for the whole window.
# shellcheck source=hosts/csb1/docker/ops136/ops136-lib.sh disable=SC1091
source "$(dirname "$0")/ops136-lib.sh"
export OPS136_PHASE=P2-CUTOVER
require_root
require_binary
take_lock

P1DIR=${1:?usage: cutover.sh <P1-artifacts-dir (contains drift-baseline.sha256)>}
[ -f "$P1DIR/drift-baseline.sha256" ] || die "no drift baseline in $P1DIR"

TS=$(date +%Y%m%d-%H%M%S)
DIR="$BACKUPS_ROOT/cutover-$TS"
mkdir -p "$DIR"
journal "cutover window opened — artifacts: $DIR"

# ── 1. preflight (fail-safe zone) ────────────────────────────────────────
systemctl is-active --quiet compose-csb1.service && die "compose-csb1.service active — staging (reconcile=false) expected"
systemctl is-active --quiet compose-csb1-update.timer && die "update timer active — staging expected"
for svc in "${SERVICES[@]}"; do
  p=$(container_project "$svc")
  case "$svc" in
  paimos-www) [ "$p" = paimos ] || die "preflight: $svc owned by '$p', expected legacy project paimos" ;;
  *) [ "$p" = inspr-at ] || die "preflight: $svc owned by '$p', expected legacy project inspr-at" ;;
  esac
done
journal "preflight PASS: staging state + legacy ownership confirmed"

# ── 2. T-0 drift gate (hashes only) ──────────────────────────────────────
# Rebuild the same baseline and compare. Any drift since P1 (config, .env
# values, agenix values, images, volumes, labels) aborts the window — the
# P1 drill's equality proof is only transitive while both sides are frozen.
BASE_NOW="$DIR/drift-now.sha256"
{
  sha256sum "$LEGACY_INSPR/docker-compose.yml" "$LEGACY_INSPR/Caddyfile" \
    "$LEGACY_PAIMOS/docker-compose.yml" "$LEGACY_PAIMOS/Caddyfile" \
    "$LEGACY_INSPR/.env" \
    /run/agenix/csb1-zitadel-env /run/agenix/csb1-zitadel-postgres-env /run/agenix/csb1-inspr-auth-env
  for svc in "${SERVICES[@]}"; do
    printf '%s  image-id:%s\n' "$(docker inspect "$svc" --format '{{.Image}}' | sha256sum | cut -d' ' -f1)" "$svc"
    docker inspect "$svc" --format '{{json .Config.Labels}}' | sha256sum | sed "s/-$/labels:$svc/"
  done
  docker volume ls --format '{{.Name}}' | grep -E 'inspr-at_|paimos_' | sort | sha256sum | sed 's/-$/volume-list/'
} >"$BASE_NOW"
diff -u "$P1DIR/drift-baseline.sha256" "$BASE_NOW" >&2 || die "T-0 DRIFT detected vs P1 baseline — re-run P1 (drill + baselines) before cutover"
journal "T-0 drift gate PASS (bit-identical to P1 baseline)"

# ── 3. fresh recovery point + offsite BEFORE any shutdown ────────────────
journal "fresh pg_dumpall + config tars"
docker exec zitadel-postgres pg_dumpall -U zitadel >"$DIR/pre-cutover-pgdumpall.sql"
[ -s "$DIR/pre-cutover-pgdumpall.sql" ] || die "empty pg_dumpall"
tar -C /home/mba/docker -cf "$DIR/legacy-config.tar" inspr-at/docker-compose.yml inspr-at/Caddyfile inspr-at/.env inspr-at/.machinekey paimos/docker-compose.yml paimos/Caddyfile
sha256sum "$DIR"/pre-cutover-pgdumpall.sql "$DIR"/legacy-config.tar >"$DIR/manifest.sha256"
restic_offsite_gate
journal "freshest recovery point is offsite — proceeding to the destructive interval"

# ── 4. POINT OF NO RETURN: stop legacy (verify), then remove ─────────────
set +e
(
  set -e
  journal "stopping legacy inspr-at (-t 120) + paimos"
  compose_legacy_inspr stop -t 120
  compose_legacy_paimos stop -t 60
  docker logs --tail 30 zitadel-postgres 2>&1 | grep -q 'database system is shut down' || {
    journal "WARN: clean-shutdown line not found in zitadel-postgres logs:"
    docker logs --tail 10 zitadel-postgres >&2 || true
    exit 40
  }
  journal "postgres shut down cleanly — removing legacy containers (down, containers only, volumes untouched)"
  compose_legacy_inspr down -t 30
  compose_legacy_paimos down -t 30
  for svc in "${SERVICES[@]}"; do
    docker inspect "$svc" >/dev/null 2>&1 && exit 41
  done
  assert_single_postgres

  journal "starting the 5 under project csb1 (scoped up from the rendered spec)"
  compose_csb1 up -d --no-build "${SERVICES[@]}"

  # ── 5. immediate smoke (deep matrix runs after in verify.sh terms) ─────
  for svc in "${SERVICES[@]}"; do
    [ "$(container_project "$svc")" = csb1 ] || exit 42
  done
  src=$(docker inspect zitadel-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')
  echo "$src" | grep -q 'inspr-at_zitadel_postgres_data' || exit 43
  docker volume ls --format '{{.Name}}' | grep -E '^csb1_(zitadel|inspr|paimos)' && exit 44
  for _ in $(seq 1 30); do
    [ "$(docker inspect zitadel-postgres --format '{{.State.Health.Status}}')" = healthy ] && break
    sleep 5
  done
  [ "$(docker inspect zitadel-postgres --format '{{.State.Health.Status}}')" = healthy ] || exit 45
  ok=""
  for _ in $(seq 1 36); do
    if docker run --rm --network csb1_traefik "$CADDY_PROBE_IMAGE" wget -q -O- --timeout=5 http://zitadel:8080/debug/healthz >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 5
  done
  [ -n "$ok" ] || exit 46
  route_smoke || exit 47
)
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  journal "CUTOVER FAILED (step code $rc) — executing automatic rollback"
  rollback_to_legacy
  if route_smoke; then
    journal "rollback verified: legacy stack serving again"
  else
    journal "ROLLBACK SMOKE FAILED — use the RUNBOOK per-service state table NOW"
  fi
  die "cutover rolled back (code $rc); evidence in $DIR and $JOURNAL"
fi

docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort >"$DIR/post-cutover-containers.txt"
journal "P2 CUTOVER COMPLETE — all 5 owned by csb1, IdP healthy, routes serving. Next: P3 verification matrix + RP logins (attended), then PR-2."
