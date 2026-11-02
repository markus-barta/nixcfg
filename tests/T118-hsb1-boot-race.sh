#!/usr/bin/env bash
# The grep patterns are literal shell text from the launcher and the module, not expansions.
# shellcheck disable=SC2016
# OPS-525 hsb1 boot race contract. Runs the real kiosk launcher and the real apc-to-mqtt publish
# step against stubs: fixed paths point into a temp dir, sleep advances a fake uptime, nc answers
# from a script. The launcher must wait for an RTSP answer at boot, stop waiting before the babycam
# watchdog's first tick, and never wait when the watchdog re-runs it later. Known harmful mutants
# of both scripts must fail the same checks.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="${repo}/hosts/hsb1/files/kiosk-autostart.sh"
config="${repo}/hosts/hsb1/configuration.nix"
watchdog="${repo}/hosts/hsb1/babycam-watchdog.nix"

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "${work}"' EXIT

# The launcher's bound only protects the watchdog's first tick while the two numbers agree.
grep -Fq 'OnBootSec = "3min"' "${watchdog}"
grep -Fq 'RTSP_WAIT_UNTIL_UPTIME=170' "${launcher}"

mkdir "${work}/bin"
stub() {
  printf '#!%s\n%s\n' "${BASH}" "$2" >"${work}/bin/$1"
  chmod +x "${work}/bin/$1"
}
stub xset 'exit 0'
stub pactl 'exit 0'
stub pgrep 'exit 1'
stub pkill 'exit 0'
# Time only passes through sleep. The call cap turns an unbounded wait into a failure, not a hang.
stub sleep "n=\$(cat '${work}/sleeps'); n=\$((n + 1)); echo \"\$n\" >'${work}/sleeps'
[ \"\$n\" -lt 500 ] || { echo 'unbounded wait' >&2; exit 99; }
read -r up _ <'${work}/uptime'; echo \"\$((\${up%%.*} + \${1%%.*})).00 0\" >'${work}/uptime'"
stub vlc "printf '%s\n' \"\$@\" >'${work}/vlc-args'; echo vlc >>'${work}/calls'"
# An OPTIONS request is the stream probe; anything else is the launcher's telnet volume talk.
stub nc "input=\$(cat)
case \"\$input\" in
  OPTIONS*)
    echo probe >>'${work}/calls'
    n=\$(grep -c probe '${work}/calls')
    if [ \"\$n\" -ge \"\$(cat '${work}/answer-after')\" ]; then
      printf 'RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n'
    else
      printf 'not rtsp\r\n'
    fi
    ;;
  *) printf '( state playing )\n' ;;
esac"

cat >"${work}/env" <<'ENV'
MINISERVER24_IP=192.0.2.1
TAPO_C210_PASSWORD=t118
ENV

# Runs one launcher text from a given uptime. answer_after = which probe gets the RTSP answer.
run_launcher() {
  local source=$1 uptime=$2 answer_after=$3
  : >"${work}/calls"
  echo 0 >"${work}/sleeps"
  echo "${uptime}.00 0" >"${work}/uptime"
  echo "${answer_after}" >"${work}/answer-after"
  sed -e "s#/proc/uptime#${work}/uptime#g" \
    -e "s#/run/agenix/hsb1-tapo-c210-env#${work}/env#g" \
    -e "s#/run/current-system/sw/bin/pactl#${work}/bin/pactl#g" \
    -e "s#/var/lib/babycam-watchdog/desired-volume#${work}/none#g" \
    "${source}" >"${work}/launcher.sh"
  PATH="${work}/bin:${PATH}" bash "${work}/launcher.sh" >"${work}/launcher.log" 2>&1
  # The launcher backgrounds VLC, so its stub may still be on its way.
  local _
  for _ in $(seq 1 50); do
    grep -q vlc "${work}/calls" && return 0
    sleep 0.1
  done
}

# All three behaviours for one launcher text; returns non-zero on the first broken one.
check_launcher() {
  local source=$1 probes

  # Boot: three probes before the answer, VLC only after it.
  run_launcher "${source}" 60 3 || return 1
  [ "$(tr '\n' ' ' <"${work}/calls")" = "probe probe probe vlc " ] || return 1

  # Boot, and the stream never answers (the port may be open): the wait ends before the watchdog's
  # first tick at 180 s, and VLC still starts.
  run_launcher "${source}" 60 100000 || return 1
  [ "$(tail -1 "${work}/calls")" = "vlc" ] || return 1
  probes=$(grep -c probe "${work}/calls") || return 1
  [ "${probes}" -ge 2 ] || return 1
  # Later sleeps belong to the volume loop, so read the bound from the probe count: 2 s per probe.
  [ $((60 + (probes - 1) * 2)) -lt 180 ] || return 1

  # A watchdog heal after the boot window: VLC at once, not one probe.
  run_launcher "${source}" 180 1 || return 1
  [ "$(head -1 "${work}/calls")" = "vlc" ] || return 1
  [ "$(grep -c probe "${work}/calls" || true)" -eq 0 ] || return 1

  # No Qt interface, so no dialog and no main window over the video. Telnet is the watchdog's and
  # the volume button's only way in, so it has to stay.
  grep -Fxq -- '--intf=dummy' "${work}/vlc-args" || return 1
  grep -Fxq -- '--extraintf=telnet' "${work}/vlc-args" || return 1
  grep -Fxq -- '--loop' "${work}/vlc-args" || return 1
  grep -Fq -- '--no-embedded-video' "${work}/vlc-args" && return 1
  [ "$(tail -1 "${work}/vlc-args")" = "rtsp://192.0.2.1:35067/9726ad778d503184" ] || return 1
}

check_launcher "${launcher}"

launcher_mutant() {
  sed -E "$1" "${launcher}" >"${work}/mutant.sh"
  cmp -s "${launcher}" "${work}/mutant.sh" && {
    echo "launcher mutant did not apply: $1" >&2
    exit 1
  }
  if check_launcher "${work}/mutant.sh" 2>/dev/null; then
    echo "launcher mutant passed: $1" >&2
    exit 1
  fi
}
launcher_mutant 's/RTSP_WAIT_UNTIL_UPTIME=170/RTSP_WAIT_UNTIL_UPTIME=400/' # runs past the watchdog's tick
launcher_mutant "s/\| grep -q '\^RTSP\/1\.0 200'//"                        # any open port counts as ready
launcher_mutant 's/^  --intf=dummy \\$/  --no-embedded-video \\/'          # Qt window and dialogs are back

# The publish step exactly as the module has it, with only the nix store path replaced.
sed -n '/^      attempt=1$/,/^      done$/p' "${config}" |
  sed 's#${pkgs.mosquitto}/bin/mosquitto_pub#mosquitto_pub#' >"${work}/publish-body.sh"
grep -Fq 'until mosquitto_pub' "${work}/publish-body.sh"

stub mosquitto_pub "n=\$(cat '${work}/pubs'); n=\$((n + 1)); echo \"\$n\" >'${work}/pubs'
[ \"\$n\" -ge \"\$(cat '${work}/pub-ok-at')\" ]"

run_publish() {
  local body=$1 ok_at=$2
  echo 0 >"${work}/pubs"
  echo 0 >"${work}/sleeps"
  echo '0.00 0' >"${work}/uptime"
  echo "${ok_at}" >"${work}/pub-ok-at"
  {
    echo 'set -euo pipefail'
    echo 'json_status={}; MOSQITTO_USER_MS24=u; MOSQITTO_PASS_MS24=p; MOSQITTO_HOST_MS24=h'
    cat "${body}"
  } >"${work}/publish.sh"
  PATH="${work}/bin:${PATH}" bash "${work}/publish.sh" >/dev/null 2>&1
}

check_publish() {
  local body=$1
  # Broker up on the second try: the unit succeeds, one retry, one pause.
  run_publish "${body}" 2 || return 1
  [ "$(cat "${work}/pubs")" -eq 2 ] && [ "$(cat "${work}/sleeps")" -eq 1 ] || return 1
  # Broker stays down: the unit fails after three tries, inside the timer's one-minute cycle.
  if run_publish "${body}" 100; then return 1; fi
  [ "$(cat "${work}/pubs")" -eq 3 ] && [ "$(cat "${work}/sleeps")" -eq 2 ] || return 1
}

check_publish "${work}/publish-body.sh"

# A broker that stays down must not read as healthy.
sed 's/\[ "\$attempt" -lt 3 \] || exit 1/[ "$attempt" -lt 3 ] || break/' "${work}/publish-body.sh" >"${work}/publish-mutant.sh"
cmp -s "${work}/publish-body.sh" "${work}/publish-mutant.sh" && {
  echo "publish mutant did not apply" >&2
  exit 1
}
if check_publish "${work}/publish-mutant.sh"; then
  echo "publish mutant passed" >&2
  exit 1
fi

echo "T118 ok"
