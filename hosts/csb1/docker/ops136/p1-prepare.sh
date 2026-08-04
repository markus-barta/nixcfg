#!/usr/bin/env bash
# OPS-136 P1 — recovery custody + baselines. Run as root on csb1 AFTER the
# staging switch (rendered file + agenix present), BEFORE the drill.
# No production mutation: reads, archives, one no-op docker load test, and a
# restic backup trigger.
# shellcheck source=hosts/csb1/docker/ops136/ops136-lib.sh disable=SC1091
source "$(dirname "$0")/ops136-lib.sh"
export OPS136_PHASE=P1-PREPARE
require_root
require_binary
take_lock

TS=$(date +%Y%m%d-%H%M%S)
DIR="$BACKUPS_ROOT/$TS"
mkdir -p "$DIR"/{images,oci}
journal "P1 artifacts dir: $DIR"

# ── 0. staging preconditions ─────────────────────────────────────────────
[ -f "$RENDERED" ] || die "rendered file missing: $RENDERED (staging switch not done?)"
grep -q 'inspr-at_zitadel_postgres_data' "$RENDERED" || die "rendered file lacks the external volume names — wrong generation?"
for f in csb1-zitadel-env csb1-zitadel-postgres-env csb1-inspr-auth-env; do
  [ -f "/run/agenix/$f" ] || die "agenix file missing: /run/agenix/$f"
  [ "$(stat -c %a:%U /run/agenix/$f)" = "400:root" ] || die "/run/agenix/$f is not 0400 root"
done
systemctl is-active --quiet compose-csb1.service && die "compose-csb1.service is active — reconcile=false staging expected"
journal "staging preconditions OK (rendered + agenix present, reconcile off)"

# ── 1. disk headroom ─────────────────────────────────────────────────────
df -h / | tee -a "$JOURNAL" >&2
docker system df | tee -a "$JOURNAL" >&2
avail_kb=$(df --output=avail -k / | tail -1 | tr -d ' ')
[ "$avail_kb" -gt 5242880 ] || die "less than 5 GiB free on / — resolve before creating archives"

# ── 2. tagless image archives + pre-load gate + engine no-op load test ───
snapshot_images() { docker images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | sort; }
PRE_IMG=$(snapshot_images)
declare -A SEEN=()
for svc in "${SERVICES[@]}"; do
  id=${IMAGE_ID[$svc]}
  [ -n "${SEEN[$id]:-}" ] && continue
  SEEN[$id]=1
  short=${id#sha256:}
  short=${short:0:12}
  tar="$DIR/images/$svc-$short.tar"
  journal "saving tagless archive for $svc ($id)"
  docker save "$id" -o "$tar"
  # Gate: archive MUST be tagless and carry the recorded ID — a tagged
  # archive could re-tag a mutable tag (e.g. postgres:16-alpine) on load.
  python3 - "$tar" "$id" <<'PY'
import json, sys, tarfile
tar, want = sys.argv[1], sys.argv[2]
with tarfile.open(tar) as t:
    man = json.load(t.extractfile("manifest.json"))
assert len(man) == 1, f"expected 1 image in archive, got {len(man)}"
tags = man[0].get("RepoTags") or []
assert tags in ([], None) or not tags, f"archive is NOT tagless: {tags}"
cfg = man[0]["Config"].split("/")[-1].removesuffix(".json")
assert f"sha256:{cfg}" == want or cfg == want.removeprefix("sha256:"), "archive config digest != recorded image ID"
print("tagless+ID gate: PASS")
PY
  journal "engine no-op load test for $svc"
  docker load -i "$tar" >/dev/null
done
POST_IMG=$(snapshot_images)
[ "$PRE_IMG" = "$POST_IMG" ] || die "image/tag table changed during no-op load test — investigate before proceeding"
journal "image archives: tagless gate + engine load test PASS (image table byte-identical)"

# ── 3. OCI exact-manifest custody for the registry images ────────────────
for svc in zitadel zitadel-postgres inspr-www; do
  ref=${REGISTRY_DIGEST[$svc]}
  hex=${ref##*sha256:}
  journal "OCI custody: $ref"
  nix run nixpkgs#skopeo -- copy --all --preserve-digests "docker://$ref" "oci:$DIR/oci/$svc" >/dev/null
  grep -q "$hex" "$DIR/oci/$svc/index.json" || die "OCI custody: index.json for $svc does not reference the recorded digest"
  [ -f "$DIR/oci/$svc/blobs/sha256/$hex" ] || die "OCI custody: top-level blob for $svc missing"
  [ "$(sha256sum "$DIR/oci/$svc/blobs/sha256/$hex" | cut -d' ' -f1)" = "$hex" ] || die "OCI custody: blob hash mismatch for $svc"
done
journal "OCI custody: PASS (paimos-www shares the inspr-www caddy digest)"

# ── 4. drift baseline (hashes only — no secret content ever printed) ─────
BASE="$DIR/drift-baseline.sha256"
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
} >"$BASE"
journal "drift baseline written: $BASE"

# ── 5. baseline route + container evidence ───────────────────────────────
{
  echo "== containers =="
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort
  echo "== routes =="
  if route_smoke; then echo "route_smoke: PASS"; else echo "route_smoke: FAIL (investigate BEFORE cutover)"; fi
} >"$DIR/baseline-evidence.txt" 2>&1
grep -q 'route_smoke: PASS' "$DIR/baseline-evidence.txt" || die "baseline route smoke failed — the estate must be green before any cutover"
journal "baseline evidence captured"

# ── 6. offsite gate ──────────────────────────────────────────────────────
restic_offsite_gate

journal "P1-PREPARE COMPLETE — artifacts in $DIR (retained: images until durable pull sources exist; see ticket)"
