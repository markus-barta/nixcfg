#!/usr/bin/env bash
# OPS-136 shared library — sourced by p1-prepare.sh / drill.sh / cutover.sh /
# rollback.sh. Everything here was adversarially reviewed on the ticket;
# change = re-review.
set -euo pipefail
umask 077

# ── constants ────────────────────────────────────────────────────────────
# Recorded at P0 from the live compose-csb1 unit. ABORT if missing — its
# absence means the prior generation was GC'd, which is itself an anomaly.
CB=/nix/store/f5qch8f2b3hch9ar5nvvadxxgnssxz6c-docker-compose-5.3.1/bin/docker-compose
RENDERED=/etc/compose/csb1/docker-compose.yml
PROJDIR=/home/mba/Code/nixcfg/hosts/csb1/docker
OPSDIR=/home/mba/Code/nixcfg/hosts/csb1/docker/ops136
LEGACY_INSPR=/home/mba/docker/inspr-at
LEGACY_PAIMOS=/home/mba/docker/paimos
BACKUPS_ROOT=/root/ops136-backups
LOCKFILE=/run/lock/compose-csb1.lock
SERVICES=(inspr-www inspr-auth zitadel-postgres zitadel paimos-www)

# Image IDs observed live 2026-08-04 (P0 evidence on OPS-136).
# Keys quoted — an unquoted hyphenated key is reformatted as arithmetic by
# shfmt, silently changing the key string.
# shellcheck disable=SC2034  # consumed by the sourcing scripts
declare -A IMAGE_ID=(
  ["inspr-www"]=sha256:af555904a0961945f16bb323a501457b13a4f7e9bde969b145b97da80b38ecbe
  ["paimos-www"]=sha256:af555904a0961945f16bb323a501457b13a4f7e9bde969b145b97da80b38ecbe
  ["inspr-auth"]=sha256:88feff29ac779e7551f28914a30aaab5338fb03e45e253194bd6c9739ea7edc8
  ["zitadel-postgres"]=sha256:667495ca2ac33180ad3690178da1bf274f481d0c43849d4c1941f0176983bd2e
  ["zitadel"]=sha256:447b552fcf142a5aedba2f8b22f36c3a86c372bc13d78c5e147b3a64fc5c4c49
)
# shellcheck disable=SC2034  # consumed by the sourcing scripts
declare -A REGISTRY_DIGEST=(
  ["zitadel"]=ghcr.io/zitadel/zitadel@sha256:5fb493fdb73204667cdd05715ef5f140049bf2781e10fd8ca407ce5aaa29f3df
  ["zitadel-postgres"]=postgres@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50
  ["inspr-www"]=caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
  ["paimos-www"]=caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
)
# shellcheck disable=SC2034  # consumed by the sourcing scripts
CADDY_PROBE_IMAGE=caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
RESTIC_CONTAINER=csb1-restic-cron-hetzner-1

JOURNAL="${BACKUPS_ROOT}/journal.log"

# ── helpers ──────────────────────────────────────────────────────────────
journal() {
  mkdir -p "$BACKUPS_ROOT"
  printf '%s [%s] %s\n' "$(date -Is)" "${OPS136_PHASE:-?}" "$*" | tee -a "$JOURNAL" >&2
}

die() {
  journal "FATAL: $*"
  exit 1
}

require_root() { [ "$(id -u)" = 0 ] || die "must run as root"; }

require_binary() {
  [ -x "$CB" ] || die "recorded compose binary missing: $CB — do NOT fall back to PATH; diagnose why the store path is gone"
}

# Acquire the campaign lock on fd 9 and HOLD it for the process lifetime.
take_lock() {
  exec 9>"$LOCKFILE"
  flock -w 60 9 || die "could not acquire $LOCKFILE within 60s"
  journal "flock acquired on $LOCKFILE (held for process lifetime)"
}

compose_csb1() { "$CB" -p csb1 -f "$RENDERED" --project-directory "$PROJDIR" "$@"; }
compose_legacy_inspr() {
  "$CB" --project-directory "$LEGACY_INSPR" -f "$LEGACY_INSPR/docker-compose.yml" \
    -f "$OPSDIR/rollback-inspr-at.override.yml" -p inspr-at "$@"
}
compose_legacy_paimos() {
  "$CB" --project-directory "$LEGACY_PAIMOS" -f "$LEGACY_PAIMOS/docker-compose.yml" \
    -f "$OPSDIR/rollback-paimos.override.yml" -p paimos "$@"
}

container_project() { docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true; }

assert_single_postgres() {
  local n
  n=$(docker ps -a --filter volume=inspr-at_zitadel_postgres_data --format '{{.Names}}' | wc -l)
  [ "$n" -le 1 ] || die "single-postgres invariant violated: $n containers reference inspr-at_zitadel_postgres_data"
}

# Trigger a restic backup inside the restic container and require a NEW
# --host csb1 snapshot (exact-ID set difference, never `latest`), then
# assert it contains the campaign backups path.
restic_offsite_gate() {
  local pre post new tries=0
  journal "restic gate: capturing pre-trigger snapshot IDs"
  pre=$(docker exec "$RESTIC_CONTAINER" sh -c 'restic $RESTIC_BACKUP_OPTIONS snapshots --host csb1 --json' | python3 -c 'import json,sys;print("\n".join(s["id"] for s in json.load(sys.stdin)))')
  docker exec "$RESTIC_CONTAINER" supervisorctl start restic_backup
  journal "restic gate: backup triggered, polling for a new csb1 snapshot"
  while :; do
    sleep 60
    tries=$((tries + 1))
    post=$(docker exec "$RESTIC_CONTAINER" sh -c 'restic $RESTIC_BACKUP_OPTIONS snapshots --host csb1 --json' | python3 -c 'import json,sys;print("\n".join(s["id"] for s in json.load(sys.stdin)))')
    new=$(comm -13 <(sort <<<"$pre") <(sort <<<"$post") | head -1)
    [ -n "$new" ] && break
    [ "$tries" -ge 45 ] && die "restic gate: no new csb1 snapshot after 45 min"
  done
  journal "restic gate: new snapshot $new — verifying it contains $BACKUPS_ROOT"
  docker exec "$RESTIC_CONTAINER" sh -c "restic \$RESTIC_BACKUP_OPTIONS ls $new /backup/root/ops136-backups" >/dev/null ||
    die "restic gate: snapshot $new does not contain /backup/root/ops136-backups"
  journal "restic gate: PASS (snapshot $new offsite)"
}

# Scoped rollback used by cutover.sh (in-process, lock already held) and by
# rollback.sh. Removes the csb1-project copies of the 5, then restores the
# legacy projects from their pinned overrides.
rollback_to_legacy() {
  journal "ROLLBACK: removing csb1-project copies of the 5 (scoped rm, never project-wide down)"
  compose_csb1 rm -sf "${SERVICES[@]}" || journal "WARN: scoped rm reported errors — continuing to state assessment"
  local c
  for c in "${SERVICES[@]}"; do
    [ "$(container_project "$c")" = "csb1" ] && die "ROLLBACK: $c still owned by project csb1 — manual state-table recovery required"
  done
  assert_single_postgres
  journal "ROLLBACK: starting legacy projects from pinned overrides (--no-build --pull never)"
  compose_legacy_inspr up -d --no-build --pull never
  compose_legacy_paimos up -d --no-build --pull never
  journal "ROLLBACK: waiting for zitadel-postgres health"
  for _ in $(seq 1 30); do
    [ "$(docker inspect zitadel-postgres --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break
    sleep 5
  done
  [ "$(docker inspect zitadel-postgres --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] || die "ROLLBACK: zitadel-postgres not healthy — state-table recovery required"
  journal "ROLLBACK: legacy projects restored"
}

route_smoke() {
  # Full-TLS origin checks with correct SNI — never -k.
  local rc=0
  curl -sS --max-time 15 --resolve auth.inspr.at:443:127.0.0.1 https://auth.inspr.at/.well-known/openid-configuration | grep -q '"issuer"' || {
    journal "SMOKE FAIL: auth.inspr.at openid-configuration"
    rc=1
  }
  curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve www.inspr.at:443:127.0.0.1 https://www.inspr.at/ | grep -qE '^(200|304)$' || {
    journal "SMOKE FAIL: www.inspr.at"
    rc=1
  }
  # Since 2026-07-25 paimos.com deliberately 301s into the inspr.at family
  # (Caddyfile redirect). Assert the exact redirect — stronger than a 200.
  curl -sS --max-time 15 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve paimos.com:443:127.0.0.1 https://paimos.com/ | grep -qE '^301 https://paimos\.inspr\.at/$' || {
    journal "SMOKE FAIL: paimos.com (expected 301 -> https://paimos.inspr.at/)"
    rc=1
  }
  curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve pharos.inspr.at:443:127.0.0.1 https://pharos.inspr.at/ | grep -qE '^(200|30[1-4])$' || {
    journal "SMOKE FAIL: pharos.inspr.at"
    rc=1
  }
  curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve inspr.at:443:127.0.0.1 https://inspr.at/login | grep -qE '^(200|30[1-3]|405)$' || {
    journal "SMOKE FAIL: inspr.at/login (inspr-auth)"
    rc=1
  }
  return "$rc"
}
