#!/usr/bin/env bash
# pixdcon v1 -> v2 display handover on hsb1 (PIXD-115). Runs ON hsb1; from a workstation:
#   ssh mba@hsb1.lan 'bash -s' -- status            < hosts/hsb1/bin/pixdcon-handover.sh
#   ssh mba@hsb1.lan 'bash -s' -- handover <device> < hosts/hsb1/bin/pixdcon-handover.sh
#   ssh mba@hsb1.lan 'bash -s' -- rollback <device> < hosts/hsb1/bin/pixdcon-handover.sh
#
# handover: v2 output=drive first (the v1 interlock keeps v2 in shadow while v1 lists the device),
# then the device is REMOVED from v1's config.json (authoritative in every v1 path, also when v1
# boots without MQTT), then proves that v2 drives it with the panel on.
# rollback: validates v1's restore entry first, then sets v2 output=shadow, waits until v2 has
# let go (shadow, no owed plug ON, home3 history quiet), puts the device back into v1's
# config.json at its original place and restarts v1 so its Home Assistant discovery wins.
# Re-running rollback after an interruption is safe. Nothing here reads or prints secrets.
set -euo pipefail

V1=http://127.0.0.1:8080
V2=http://127.0.0.1:8082
V1_FILE=/home/mba/docker/mounts/pixdcon/config.json
STATE_DIR=/home/mba/docker/mounts/pixdcon/scenes/pixoo/.state
BACKUP_ROOT=/home/mba/backups/pixdcon
ORIGINAL="$BACKUP_ROOT/pixd115-original-v1-config.json"

die() {
  echo "FAIL: $*" >&2
  exit 1
}
say() { echo "$(date +%T) $*"; }
cg() { curl -sf --max-time 5 "$@"; }
py() { python3 -c "$1" "${@:2}"; }

v2_status() { cg "$V2/api/v2/status"; }
v2_device() { cg "$V2/api/v2/devices/$1"; }
v1_status() { cg "$V1/api/status"; }
v1_file() { cg "$V1/api/config/file"; }

# wait_for <seconds> <description> <command...>: poll every 2 s against the wall clock.
wait_for() {
  local limit=$1 what=$2 start
  shift 2
  start=$(date +%s)
  until "$@"; do
    [ $(($(date +%s) - start)) -ge "$limit" ] && die "timeout after ${limit}s waiting for: $what"
    sleep 2
  done
  say "ok: $what ($(($(date +%s) - start))s)"
}

# set_v2_output <device> <drive|shadow>: change one device's output through the validated raw-config API.
set_v2_output() {
  local tmp rc=0
  tmp=$(mktemp)
  cg "$V2/api/v2/config/raw" >"$tmp" || rc=1
  [ "$rc" -eq 0 ] && py '
import json,sys
r=json.load(open(sys.argv[1])); c=json.loads(r["text"]); dev,out=sys.argv[2],sys.argv[3]
hits=[d for d in c["devices"] if d["name"]==dev]
assert len(hits)==1, "device not in v2 config"
hits[0]["output"]=out
json.dump({"text":json.dumps(c,indent=2)+"\n"},open(sys.argv[1],"w"))' "$tmp" "$1" "$2" || rc=1
  [ "$rc" -eq 0 ] && { cg -X PUT -H 'Content-Type: application/json' --data-binary @"$tmp" "$V2/api/v2/config/raw" |
    py 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("state",{}).get("valid") else 1)' || rc=1; }
  rm -f "$tmp"
  return "$rc"
}

# Predicates fail (non-zero) on any HTTP/JSON error, so missing evidence never counts as success.
v1_runs() {
  local s
  s=$(v1_status) || return 2
  py 'import json,sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1])["deviceHealth"] else 1)' "$s" "$1"
}
v1_stopped() {
  local rc=0
  v1_runs "$1" || rc=$?
  [ "$rc" -eq 1 ]
}
# v2_v1list <device> <with|without>: v2's copy of v1's list, received on v2's CURRENT MQTT connection.
v2_v1list() {
  local s
  s=$(v2_status) || return 2
  py '
import json,sys
s=json.loads(sys.argv[1]); v=s["v1"]; dev,want=sys.argv[2],sys.argv[3]
fresh=v["known"] and v["connection"]==s["mqtt"]["connection"] and s["mqtt"]["state"]=="connected"
inside=dev in v["devices"]
sys.exit(0 if fresh and (inside if want=="with" else not inside) else 1)' "$s" "$1" "$2"
}
v2_shadows() {
  local d
  d=$(v2_device "$1") || return 2
  py 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["health"]["state"]=="shadow" and d["desired"]["output"]=="shadow" else 1)' "$d"
}
# v2_held <device>: output drive requested in v2's config, but the interlock still holds it in shadow.
# (desired.output in the device API is the RESOLVED mode, so the request is read from the config.)
v2_held() {
  local d r
  d=$(v2_device "$1") || return 2
  r=$(cg "$V2/api/v2/config/raw") || return 2
  py '
import json,sys
d=json.loads(sys.argv[1]); c=json.loads(json.loads(sys.argv[2])["text"]); dev=sys.argv[3]
req=[x.get("output") for x in c["devices"] if x["name"]==dev]
sys.exit(0 if req==["drive"] and d["desired"]["output"]=="shadow" and d["health"]["state"]=="shadow" else 1)' "$d" "$r" "$1"
}
# v2_drives <device>: output drive, no output problem, health online/idle, panel mode play, scene active.
v2_drives() {
  local d
  d=$(v2_device "$1") || return 2
  py '
import json,sys
d=json.loads(sys.argv[1]); de=d["desired"]
ok=(de["output"]=="drive" and not de.get("outputProblem") and d["health"]["state"] in ("online","idle")
    and (de.get("mode") or {}).get("value")=="play" and d["effective"]["phase"] in ("running","builtin")
    and (d["effective"].get("scene") or "") not in ("builtin:black","builtin:off"))
sys.exit(0 if ok else 1)' "$d"
}
# frames_advance <device>: for a running scene, frames and device contact move within 6 s.
frames_advance() {
  local a b
  a=$(v2_device "$1") || return 2
  sleep 6
  b=$(v2_device "$1") || return 2
  py '
import json,sys,datetime as dt
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
if b["effective"]["phase"]=="builtin": sys.exit(0)  # built-in channel: no frames by design; check the panel/telemetry
age=(dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(b["health"]["lastContactAt"].replace("Z","+00:00"))).total_seconds()
sys.exit(0 if b["effective"]["frameCount"]>a["effective"]["frameCount"] and age<15 else 1)' "$a" "$b"
}
# plug_settled <device>: v2's last plug event for this device in the last 24 h is "plug ON confirmed"
# (or there is none). OFF, ON offline/timeout/error/failed and "ON unconfirmed" all mean ON is still owed.
plug_settled() {
  local last
  last=$(docker logs --since 24h pixdcon2-edge 2>&1 | grep -E "\[(PlugRecovery|RenderLoop)\] $1: (plug (OFF|ON)|stop deadline reached with plug ON unconfirmed)" | tail -1 || true)
  [ -z "$last" ] && return 0
  case "$last" in
  *"plug ON confirmed"*) return 0 ;;
  *) return 1 ;;
  esac
}
# history_quiet: home3's shared history file has not changed for 60 s (no writer left, final flush done).
history_quiet() {
  local f="$STATE_DIR/home3-boiler.json" m1 m2
  [ -e "$f" ] || return 0
  m1=$(stat -c %Y "$f")
  sleep 60
  m2=$(stat -c %Y "$f")
  [ "$m1" = "$m2" ]
}

preflight() {
  local dev=$1 s d
  s=$(v2_status) || die "v2 status unreadable"
  d=$(v2_device "$dev") || die "v2 has no device $dev"
  py '
import json,sys
s=json.loads(sys.argv[1]); d=json.loads(sys.argv[2]); c=s["controller"]
p=[]
if c["forceShadow"]: p.append("v2 still has FORCE_SHADOW (switch the PR first)")
if not c["mqttNamespace"]["transition"]: p.append("v2 transition is off: no v1 interlock")
if c["blobWriter"]["writer"]: p.append("v2 is the blob writer")
if s["mqtt"]["state"]!="connected": p.append("v2 MQTT not connected")
if not s["config"]["valid"]: p.append("v2 config invalid")
if not d["desired"]["enabled"]: p.append("device disabled in v2")
if (d["desired"].get("mode") or {}).get("value")!="play": p.append("device mode is not play (panel would stay off): "+str(d["desired"].get("mode")))
print("\n".join("PRE: "+x for x in p)); sys.exit(1 if p else 0)' "$s" "$d" || die "v2 preconditions"
  cg "$V2/api/v2/overlays" | py '
import json,sys
bad=[o["topic"] for o in json.load(sys.stdin) if o.get("kind") in ("blob","enabled","device-enabled") or (o.get("topic") or "").endswith("/overlay/blob") or "/enabled" in (o.get("topic") or "")]
print("PRE: retained blob/enabled overlays:",bad) if bad else None; sys.exit(1 if bad else 0)' || die "a retained blob or enabled overlay exists (or overlays unreadable)"
}

cmd=${1:-status}
dev=${2:-}
case "$cmd" in
status)
  s=$(v2_status) || die "v2 status unreadable"
  py 'import json,sys; s=json.loads(sys.argv[1]); c=s["controller"]; print("v2 forceShadow",c["forceShadow"],"transition",c["mqttNamespace"]["transition"],"blobWriter",c["blobWriter"],"mqtt",s["mqtt"]["state"],"conn",s["mqtt"]["connection"]); print("v2 sees v1 list",s["v1"]["devices"],"conn",s["v1"]["connection"],"at",s["v1"]["receivedAt"])' "$s"
  v1_file | py 'import json,sys; print("v1 file devices",[d["name"] for d in json.load(sys.stdin)["devices"]])'
  v1_status | py 'import json,sys; print("v1 running",sorted(json.load(sys.stdin)["deviceHealth"]))'
  for d in ulanzi-56 ulanzi-57 pixoo-159 pixoo-189; do
    v2_device "$d" | py 'import json,sys; d=json.load(sys.stdin); print(" ",d["name"],"output",d["desired"]["output"],"problem",d["desired"].get("outputProblem"),"mode",(d["desired"].get("mode") or {}).get("value"),"health",d["health"]["state"],"phase",d["effective"]["phase"],"frames",d["effective"]["frameCount"],"lastContact",d["health"]["lastContactAt"])'
  done
  if [ -f "$ORIGINAL" ]; then echo "original v1 config saved: $ORIGINAL"; fi
  ;;
handover)
  [ -n "$dev" ] || die "usage: handover <device>"
  preflight "$dev"
  v1_runs "$dev" || die "$dev is not running in v1"
  v2_v1list "$dev" with || die "v2 has no current v1 list containing $dev"
  v1_file | py '
import json,sys,urllib.request
dev=sys.argv[1]; d=[x for x in json.load(sys.stdin)["devices"] if x["name"]==dev]
assert len(d)==1, "device not in v1 file"
v2=json.load(urllib.request.urlopen("http://127.0.0.1:8082/api/v2/devices/"+dev,timeout=5))
v1ip=d[0]["ip"]; v2ip=(v2["desired"]["address"] or {}).get("value")
print("v1 ip",v1ip,"v2 address",v2ip); sys.exit(0 if v2ip==v1ip else 1)' "$dev" || die "v1 and v2 disagree on $dev's address"
  mkdir -p "$BACKUP_ROOT"
  [ -f "$ORIGINAL" ] || cp -a "$V1_FILE" "$ORIGINAL"
  B="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-pixd115-$dev"
  mkdir -m 700 "$B"
  cp -a "$V1_FILE" "$B/v1-config.json"
  cg "$V2/api/v2/config/raw" | py 'import json,sys; sys.stdout.write(json.load(sys.stdin)["text"])' >"$B/v2-config.json"
  say "backup $B (original order: $ORIGINAL)"
  say "step 1: v2 output=drive for $dev (stays shadow while v1 lists it)"
  set_v2_output "$dev" drive || die "v2 refused output=drive; nothing else changed"
  sleep 3
  v2_held "$dev" || die "interlock not holding (v2 not in shadow while v1 lists $dev). ROLL BACK: rollback $dev"
  say "step 2: remove $dev from v1's config.json"
  v1_file | py 'import json,sys; c=json.load(sys.stdin); c["devices"]=[d for d in c["devices"] if d["name"]!=sys.argv[1]]; json.dump(c,sys.stdout)' "$dev" |
    cg -X POST -H 'Content-Type: application/json' --data-binary @- "$V1/api/config/file" >/dev/null ||
    die "v1 refused the config; v1 should still drive $dev (v2 is held). Check: status; undo: rollback $dev"
  wait_for 30 "v1 stopped $dev" v1_stopped "$dev"
  wait_for 30 "v2's current v1 list lacks $dev" v2_v1list "$dev" without
  wait_for 60 "v2 drives $dev (panel on, scene active)" v2_drives "$dev"
  wait_for 30 "frames and device contact advance on $dev" frames_advance "$dev"
  sleep 10
  v2_drives "$dev" || die "v2 stopped driving $dev within 10 s. ROLL BACK: rollback $dev"
  say "DONE handover $dev (backup $B)"
  ;;
rollback)
  [ -n "$dev" ] || die "usage: rollback <device>"
  [ -f "$ORIGINAL" ] || die "no original v1 config at $ORIGINAL"
  # Validate the restore entry BEFORE touching v2: it comes from the original v1 config.
  cur=$(v1_file) || die "v1 config unreadable; nothing changed"
  py '
import json,sys
cur=json.loads(sys.argv[1]); orig=json.load(open(sys.argv[2])); dev=sys.argv[3]
assert any(d["name"]==dev for d in orig["devices"]), "device not in the original v1 config"
print("v1 file already has",dev,":",any(d["name"]==dev for d in cur["devices"]))' "$cur" "$ORIGINAL" "$dev" || die "restore entry invalid; nothing changed"
  say "step 1: v2 output=shadow for $dev"
  set_v2_output "$dev" shadow || die "v2 refused output=shadow; nothing else changed, re-run: rollback $dev"
  wait_for 60 "v2 let go of $dev (shadow)" v2_shadows "$dev"
  wait_for 120 "no plug ON owed by v2 for $dev" plug_settled "$dev"
  wait_for 240 "home3 history file quiet for 60 s" history_quiet
  say "step 2: put $dev back into v1's config.json at its original position"
  v1_file | py '
import json,sys
cur=json.load(sys.stdin); orig=json.load(open(sys.argv[1])); dev=sys.argv[2]
order=[d["name"] for d in orig["devices"]]
cur["devices"]=[d for d in cur["devices"] if d["name"]!=dev]+[d for d in orig["devices"] if d["name"]==dev]
cur["devices"].sort(key=lambda d: order.index(d["name"]) if d["name"] in order else len(order))
json.dump(cur,sys.stdout)' "$ORIGINAL" "$dev" |
    cg -X POST -H 'Content-Type: application/json' --data-binary @- "$V1/api/config/file" >/dev/null ||
    die "v1 refused the restore: $dev is dark now (v2 shadow, not in v1). Fix and re-run: rollback $dev"
  t0=$(date +%s)
  until v1_runs "$dev"; do
    if [ $(($(date +%s) - t0)) -ge 30 ]; then
      say "v1's hot reload did not start $dev within 30 s; the entry is on disk, the restart below recovers it"
      break
    fi
    sleep 2
  done
  say "step 3: restart v1 so it runs $dev and its Home Assistant discovery replaces v2's retained one"
  docker restart pixdcon >/dev/null || die "docker restart pixdcon failed: $dev is in v1's file but may be dark. Recover: docker restart pixdcon; then re-run: rollback $dev"
  t0=$(date +%s)
  until v1_runs "$dev"; do
    [ $(($(date +%s) - t0)) -ge 90 ] && die "v1 does not run $dev after the restart (entry is on disk; v2 is shadow). Recover: check docker logs pixdcon, fix, docker restart pixdcon, re-run: rollback $dev"
    sleep 2
  done
  say "ok: v1 runs $dev after restart"
  wait_for 60 "v2's current v1 list contains $dev" v2_v1list "$dev" with
  say "DONE rollback $dev. Check Home Assistant: none of the device's MQTT discovery payloads references pixdcon2-edge, and its telemetry is fresh"
  ;;
*) die "unknown command $cmd" ;;
esac
