#!/usr/bin/env bash
# pixdcon v1 -> v2 display handover on hsb1 (PIXD-115). Runs ON hsb1; from a workstation:
#   ssh mba@hsb1.lan 'bash -s' -- status            < hosts/hsb1/bin/pixdcon-handover.sh
#   ssh mba@hsb1.lan 'bash -s' -- handover <device> < hosts/hsb1/bin/pixdcon-handover.sh
#   ssh mba@hsb1.lan 'bash -s' -- rollback <device> <backup-dir> < hosts/hsb1/bin/pixdcon-handover.sh
#
# handover: v2 output=drive first (the v1 interlock keeps v2 in shadow while v1 lists the device),
# then the device is REMOVED from v1's config.json (authoritative in every v1 path, also when v1
# boots without MQTT), then waits until v2 drives it. rollback: v2 output=shadow first, waits until
# v2 has stopped driving it, then puts the device entry back into v1's config.json at its old place.
# Both refuse to start unless the preconditions hold. Nothing here reads or prints secrets.
set -euo pipefail

V1=http://127.0.0.1:8080
V2=http://127.0.0.1:8082
BACKUP_ROOT=/home/mba/backups/pixdcon

die() {
  echo "FAIL: $*" >&2
  exit 1
}
say() { echo "$(date +%T) $*"; }

# py <script> [args...]: JSON helpers; reads documents passed as files.
py() { python3 -c "$1" "${@:2}"; }

v2_status() { curl -sf "$V2/api/v2/status"; }
v2_device() { curl -sf "$V2/api/v2/devices/$1"; }
v1_status() { curl -sf "$V1/api/status"; }
v1_file() { curl -sf "$V1/api/config/file"; }

# set_v2_output <device> <drive|shadow>: change one device's output through the validated raw-config API.
set_v2_output() {
  local tmp
  tmp=$(mktemp)
  curl -sf "$V2/api/v2/config/raw" >"$tmp"
  py '
import json,sys
raw=json.load(open(sys.argv[1])); cfg=json.loads(raw["text"]); dev,out=sys.argv[2],sys.argv[3]
hits=[d for d in cfg["devices"] if d["name"]==dev]
assert len(hits)==1, "device not in v2 config"
hits[0]["output"]=out
json.dump({"text":json.dumps(cfg,indent=2)+"\n"},open(sys.argv[1],"w"))' "$tmp" "$1" "$2"
  curl -sf -X PUT -H 'Content-Type: application/json' --data-binary @"$tmp" "$V2/api/v2/config/raw" |
    py 'import json,sys; r=json.load(sys.stdin); v=r.get("state",{}).get("valid"); print("v2 config valid:",v); sys.exit(0 if v else 1)'
  rm -f "$tmp"
}

# wait_for <seconds> <description> <command...>: poll every 2 s until the command succeeds.
wait_for() {
  local limit=$1 what=$2
  shift 2
  local t=0
  until "$@"; do
    t=$((t + 2))
    [ "$t" -ge "$limit" ] && die "timeout after ${limit}s waiting for: $what"
    sleep 2
  done
  say "ok: $what (${t}s)"
}

v1_lists() { v1_status | py 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin)["deviceHealth"] else 1)' "$1"; }
v1_drops() { ! v1_lists "$1"; }
v2_sees_v1_list_with() { v2_status | py 'import json,sys; v=json.load(sys.stdin)["v1"]; sys.exit(0 if sys.argv[1] in v["devices"] else 1)' "$1"; }
v2_sees_v1_list_without() { v2_status | py 'import json,sys; v=json.load(sys.stdin)["v1"]; sys.exit(0 if v["known"] and sys.argv[1] not in v["devices"] else 1)' "$1"; }
v2_drives() { v2_device "$1" | py 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["desired"]["output"]=="drive" and d["health"]["state"] in ("online","idle") and not d["desired"].get("outputProblem") else 1)'; }
v2_shadows() { v2_device "$1" | py 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["health"]["state"]=="shadow" else 1)'; }

preflight() {
  local dev=$1
  v2_status | py '
import json,sys
s=json.load(sys.stdin); c=s["controller"]; dev=sys.argv[1]
problems=[]
if c["forceShadow"]: problems.append("v2 still has FORCE_SHADOW (switch the PR first)")
if not c["mqttNamespace"]["transition"]: problems.append("v2 transition is off: no v1 interlock")
if c["blobWriter"]["writer"]: problems.append("v2 is the blob writer")
if s["mqtt"]["state"]!="connected": problems.append("v2 MQTT not connected")
if not s["config"]["valid"]: problems.append("v2 config invalid")
v=s["v1"]
if not v["known"] or v["connection"]!=s["mqtt"]["connection"]: problems.append("v2 has no v1 list on its current MQTT connection")
print("\n".join("PRE: "+p for p in problems)); sys.exit(1 if problems else 0)' "$dev" || die "v2 preconditions"
  curl -sf "$V2/api/v2/overlays" | py '
import json,sys
bad=[o["topic"] for o in json.load(sys.stdin) if o.get("kind") in ("blob","device-enabled","enabled") or "/enabled" in (o.get("topic") or "") or (o.get("topic") or "").endswith("/overlay/blob")]
print("PRE: retained blob/enabled overlays:",bad) if bad else None; sys.exit(1 if bad else 0)' || die "a retained blob or enabled overlay exists; v1 could re-add or re-enable the device"
}

cmd=${1:-status}
dev=${2:-}
case "$cmd" in
status)
  v2_status | py 'import json,sys; s=json.load(sys.stdin); c=s["controller"]; print("v2 forceShadow",c["forceShadow"],"transition",c["mqttNamespace"]["transition"],"blobWriter",c["blobWriter"],"mqtt",s["mqtt"]["state"],"conn",s["mqtt"]["connection"]); print("v2 sees v1 list",s["v1"]["devices"],"conn",s["v1"]["connection"],"at",s["v1"]["receivedAt"])'
  v1_file | py 'import json,sys; print("v1 file devices",[d["name"] for d in json.load(sys.stdin)["devices"]])'
  v1_status | py 'import json,sys; print("v1 running",sorted(json.load(sys.stdin)["deviceHealth"]))'
  for d in $(v1_file | py 'import json,sys; print(" ".join(d["name"] for d in json.load(sys.stdin)["devices"]))') ulanzi-56 ulanzi-57 pixoo-159 pixoo-189; do echo "$d"; done | sort -u | while read -r d; do
    v2_device "$d" | py 'import json,sys; d=json.load(sys.stdin); print(" ",d["name"],"output",d["desired"]["output"],"problem",d["desired"].get("outputProblem"),"health",d["health"]["state"],"phase",d["effective"]["phase"],"frames",d["effective"]["frameCount"],"lastContact",d["health"]["lastContactAt"])'
  done
  ;;
handover)
  [ -n "$dev" ] || die "usage: handover <device>"
  preflight "$dev"
  v1_lists "$dev" || die "$dev is not running in v1"
  v2_sees_v1_list_with "$dev" || die "v2's v1 list does not contain $dev"
  v1_file | py '
import json,sys,subprocess
dev=sys.argv[1]; d=[x for x in json.load(sys.stdin)["devices"] if x["name"]==dev]
assert len(d)==1, "device not in v1 file"
v2=json.loads(subprocess.run(["curl","-sf","http://127.0.0.1:8082/api/v2/devices/"+dev],capture_output=True,text=True,check=True).stdout)
v1ip=d[0]["ip"]; v2ip=(v2["desired"]["address"] or {}).get("value")
print("v1 ip",v1ip,"v2 address",v2ip); sys.exit(0 if v2ip==v1ip else 1)' "$dev" || die "v1 and v2 disagree on $dev's address"
  ts=$(date +%Y%m%d-%H%M%S)
  B="$BACKUP_ROOT/$ts-pixd115-$dev"
  mkdir -p "$BACKUP_ROOT"
  mkdir -m 700 "$B"
  cp -a /home/mba/docker/mounts/pixdcon/config.json "$B/v1-config.json"
  curl -sf "$V2/api/v2/config/raw" | py 'import json,sys; sys.stdout.write(json.load(sys.stdin)["text"])' >"$B/v2-config.json"
  say "backup $B"
  say "step 1: v2 output=drive for $dev (stays shadow while v1 lists it)"
  set_v2_output "$dev" drive
  sleep 2
  v2_shadows "$dev" || die "v2 left shadow for $dev while v1 still lists it: interlock not holding; ROLL BACK: rollback $dev $B"
  say "step 2: remove $dev from v1's config.json"
  v1_file | py '
import json,sys
cfg=json.load(sys.stdin); dev=sys.argv[1]
cfg["devices"]=[d for d in cfg["devices"] if d["name"]!=dev]
json.dump(cfg,sys.stdout)' "$dev" | curl -sf -X POST -H 'Content-Type: application/json' --data-binary @- "$V1/api/config/file" >/dev/null
  wait_for 30 "v1 stopped $dev" v1_drops "$dev"
  wait_for 30 "v2 received v1's list without $dev" v2_sees_v1_list_without "$dev"
  wait_for 60 "v2 drives $dev" v2_drives "$dev"
  sleep 10
  v2_drives "$dev" || die "v2 stopped driving $dev within 10 s"
  say "DONE handover $dev (backup $B)"
  ;;
rollback)
  B=${3:-}
  [ -n "$dev" ] && [ -f "$B/v1-config.json" ] || die "usage: rollback <device> <backup-dir with v1-config.json>"
  say "step 1: v2 output=shadow for $dev"
  set_v2_output "$dev" shadow
  wait_for 60 "v2 stopped driving $dev" v2_shadows "$dev"
  sleep 5 # let v2's outgoing scene flush (home3 history) and any plug recovery settle
  say "step 2: put $dev back into v1's config.json at its old position"
  v1_file | py '
import json,sys
cur=json.load(sys.stdin); old=json.load(open(sys.argv[1])); dev=sys.argv[2]
entry=[d for d in old["devices"] if d["name"]==dev]; assert len(entry)==1, "device not in backup"
names=[d["name"] for d in old["devices"]]; idx=names.index(dev)
before=set(names[:idx]); pos=sum(1 for d in cur["devices"] if d["name"] in before)
cur["devices"]=[d for d in cur["devices"] if d["name"]!=dev]; cur["devices"].insert(pos,entry[0])
json.dump(cur,sys.stdout)' "$B/v1-config.json" "$dev" | curl -sf -X POST -H 'Content-Type: application/json' --data-binary @- "$V1/api/config/file" >/dev/null
  wait_for 30 "v1 runs $dev again" v1_lists "$dev"
  wait_for 30 "v2 received v1's list with $dev" v2_sees_v1_list_with "$dev"
  say "DONE rollback $dev; now check HA: pixdcon_${dev//-/_} entities available and telemetry fresh; if stale, restart v1 (docker restart pixdcon)"
  ;;
*) die "unknown command $cmd" ;;
esac
