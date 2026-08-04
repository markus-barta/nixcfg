#!/usr/bin/env bash
# OPS-136 P1 drill — full integration test of the CANDIDATE stack in an
# isolated shadow project, including a restored zitadel database clone and
# the in-process env/cmd equality proof. No production mutation; the drill
# network is --internal (no egress: a restored production IdP clone must not
# call out).
# shellcheck source=hosts/csb1/docker/ops136/ops136-lib.sh disable=SC1091
source "$(dirname "$0")/ops136-lib.sh"
export OPS136_PHASE=P1-DRILL
require_root
require_binary
take_lock

DP=ops136drill
NET=ops136-drill
MK=/dev/shm/ops136-drill
TS=$(date +%Y%m%d-%H%M%S)
DIR="$BACKUPS_ROOT/drill-$TS"
mkdir -p "$DIR"

compose_drill() { "$CB" -p "$DP" -f "$RENDERED" -f "$OPSDIR/drill-override.yml" --project-directory "$PROJDIR" "$@"; }

cleanup() {
  journal "drill cleanup: tearing down shadow project, network, tmpfs copy"
  compose_drill down -v --timeout 20 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$MK"
}
trap cleanup EXIT

# ── 0. isolation prerequisites ───────────────────────────────────────────
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --internal "$NET" >/dev/null
[ "$(docker network inspect "$NET" --format '{{.Internal}}')" = true ] || die "$NET is not --internal"
mkdir -p "$MK"
cp -a "$LEGACY_INSPR/.machinekey" "$MK/machinekey"
chown -R 1000:1000 "$MK"
chmod 700 "$MK" "$MK/machinekey"
journal "drill network (--internal) + tmpfs machinekey copy ready"

# ── 1. create candidates (NOT started) and assert full isolation ─────────
compose_drill create "${SERVICES[@]}"
for svc in "${SERVICES[@]}"; do
  c="$DP-$svc-1"
  [ "$(container_project "$c")" = "$DP" ] || die "$c: wrong project"
  [ "$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}')" = no ] || die "$c: restart policy not 'no'"
  # No separator in the template: with exactly one network this equals $NET;
  # any extra network breaks the equality. No external trimming tools needed.
  nets=$(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
  [ "$nets" = "$NET" ] || die "$c: networks '$nets' != $NET"
  [ "$(docker inspect "$c" --format '{{len .HostConfig.PortBindings}}')" = 0 ] || die "$c: has published ports"
  docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' | grep -q '^traefik.enable=false$' || die "$c: traefik.enable=false missing"
  docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' | grep -q '^traefik\.http' && die "$c: carries production traefik.http.* labels"
  # No production writable state: every mount must be ro, a drill volume, or
  # the tmpfs machinekey copy.
  docker inspect "$c" --format '{{range .Mounts}}{{.Type}} {{.Source}} {{.RW}}{{"\n"}}{{end}}' | while read -r typ src rw; do
    [ -z "$typ" ] && continue
    if [ "$rw" = true ]; then
      case "$src" in
      /var/lib/docker/volumes/${DP}_*) : ;;
      "$MK/machinekey") : ;;
      *) die "$c: WRITABLE mount to non-drill path: $src" ;;
      esac
    fi
  done
done
journal "isolation assertions PASS on all 5 created candidates"

# ── 1.5 in-process env/cmd equality (the transcription proof) ────────────
# Runs on the CREATED containers before anything starts: .Config is fixed
# at create time, so the proof lands even if a later integration step
# fails, and it covers services (inspr-auth) that cannot fully run inside
# the no-egress drill network.
python3 "$OPSDIR/env-equality.py" | tee "$DIR/env-equality.txt" >&2
grep -q '^RESULT: PASS$' "$DIR/env-equality.txt" || die "env equality FAILED — fix the agenix transcription before any cutover"
journal "env/cmd equality PASS (transcription proven byte-exact)"

# ── 2. clone DB: start drill postgres, restore live dump (fatal on error) ─
compose_drill start zitadel-postgres
for _ in $(seq 1 30); do
  [ "$(docker inspect "$DP-zitadel-postgres-1" --format '{{.State.Health.Status}}')" = healthy ] && break
  sleep 5
done
[ "$(docker inspect "$DP-zitadel-postgres-1" --format '{{.State.Health.Status}}')" = healthy ] || die "drill postgres not healthy"
journal "restoring live pg_dumpall into the drill clone (ON_ERROR_STOP=1)"
docker exec zitadel-postgres pg_dumpall -U zitadel | tee "$DIR/drill-pgdumpall.sql" |
  docker exec -i "$DP-zitadel-postgres-1" psql -q -U postgres -v ON_ERROR_STOP=1 >/dev/null
sha256sum "$DIR/drill-pgdumpall.sql" >"$DIR/drill-pgdumpall.sql.sha256"
# PII-free integrity indicators: counts + names of system-level objects only.
{
  echo "== databases =="
  docker exec "$DP-zitadel-postgres-1" psql -U postgres -Atc "select datname from pg_database where not datistemplate order by 1"
  echo "== roles (count) =="
  docker exec "$DP-zitadel-postgres-1" psql -U postgres -Atc "select count(*) from pg_roles"
  echo "== zitadel user tables (count) =="
  docker exec "$DP-zitadel-postgres-1" psql -U postgres -d zitadel -Atc "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')"
} | tee "$DIR/restore-integrity.txt" >&2
grep -q '^zitadel$' "$DIR/restore-integrity.txt" || die "restored cluster has no zitadel database"
journal "restore drill PASS (indicators in $DIR/restore-integrity.txt)"

# ── 3. start candidate zitadel against the clone; assert readiness ───────
compose_drill start zitadel
probe() { docker run --rm --network "$NET" "$CADDY_PROBE_IMAGE" wget -q -O- --timeout=5 "$1" 2>/dev/null; }
ok=""
for _ in $(seq 1 36); do
  if probe http://zitadel:8080/debug/healthz >/dev/null || probe http://zitadel:8080/healthz >/dev/null; then
    ok=1
    break
  fi
  sleep 5
done
[ -n "$ok" ] || {
  docker logs --tail 40 "$DP-zitadel-1" >&2
  die "candidate zitadel never became healthy against the restored clone"
}
journal "candidate zitadel READY against restored production data (masterkey + DB password functionally proven)"

# ── 4. start the web candidates; content assertions from a sibling ───────
compose_drill start inspr-www paimos-www inspr-auth
sleep 3
probe_hdr() { docker run --rm --network "$NET" "$CADDY_PROBE_IMAGE" wget -q -O- --timeout=5 --header "Host: $2" "$1" 2>/dev/null; }
probe_hdr http://inspr-www:80/ www.inspr.at | grep -qi 'html' || die "inspr-www drill serves no content for www.inspr.at"
# paimos-www is a pure whole-host 301 to paimos.inspr.at since 2026-07-25
# (Caddyfile: "paimos.com is deprecated"). Assert the exact redirect; wget
# would try to FOLLOW it (unresolvable on the --internal net), so capture
# the first response's headers and ignore the follow-up failure.
paimos_hdrs=$(docker run --rm --network "$NET" "$CADDY_PROBE_IMAGE" sh -c 'wget -q -S -O /dev/null --timeout=5 --header "Host: paimos.com" http://paimos-www:80/ 2>&1 || true')
echo "$paimos_hdrs" | grep -q ' 301 ' || die "paimos-www drill: expected 301 redirect, headers: $(echo "$paimos_hdrs" | head -2 | tr '\n' ' ')"
echo "$paimos_hdrs" | grep -qi 'Location: https://paimos\.inspr\.at/' || die "paimos-www drill: wrong redirect target"
# inspr-auth performs OIDC discovery against its issuer at startup and
# FAIL-FAST-EXITS when unreachable — and the drill network is --internal
# precisely so a clone holding production PATs can never reach the real
# IdP. Two acceptable outcomes, both proving the binary ran with the
# candidate env: (a) it serves /login (a future version that lazy-inits),
# or (b) it exited 1 with the discovery-failure line naming the candidate
# OIDC_ISSUER — env delivery proven, runtime behavior identical to what
# the live binary would do in isolation. Live /login behavior is verified
# in P3 post-cutover.
sleep 3
ia_state=$(docker inspect "$DP-inspr-auth-1" --format '{{.State.Status}} {{.State.ExitCode}}')
code=$(docker run --rm --network "$NET" "$CADDY_PROBE_IMAGE" sh -c 'wget -q -S -O /dev/null --timeout=5 http://inspr-auth:8080/login 2>&1 | awk "/HTTP\//{print \$2}" | tail -1' || true)
if echo "$code" | grep -qE '^(200|30[1-3]|405)$'; then
  journal "inspr-auth drill: serving /login ($code)"
elif [ "$ia_state" = "exited 1" ] && docker logs "$DP-inspr-auth-1" 2>&1 | grep -q 'oidc: discovery failed for https://auth\.inspr\.at'; then
  journal "inspr-auth drill: expected no-egress fail-fast (discovery against candidate OIDC_ISSUER proven; live behavior verified in P3)"
else
  docker logs --tail 20 "$DP-inspr-auth-1" >&2 || true
  die "inspr-auth drill: state '$ia_state', /login '$code' — neither serving nor the documented fail-fast"
fi
journal "web candidates verified (inspr-www content, paimos-www 301, inspr-auth)"

journal "P1-DRILL COMPLETE: isolation, restore, candidate-IdP readiness, content, env equality — ALL PASS (evidence: $DIR)"
