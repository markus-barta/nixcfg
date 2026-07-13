# Babycam health watchdog — NIX-151.
#
# WHY THIS EXISTS
# ===============
# On 2026-07-12 the babycam went silent with a perfect picture and nothing
# noticed. Markus found out because he could not hear his son. On 2026-07-13,
# while merely *looking* at the host to design this watchdog, it had happened
# AGAIN. A safety device that fails quietly is worse than no device, because
# it is trusted.
#
# THE CENTRAL DESIGN CONSTRAINT: 0 IS A LEGITIMATE VOLUME
# =======================================================
# The obvious watchdog ("volume is 0 -> it's broken -> fix it") is WRONG and
# would have been actively harmful. Volume 0 is set DELIBERATELY, most nights:
# with the bedroom door open the boy is audible directly, so the kiosk gets
# muted via the MQTT button. The journal shows the ritual plainly — 512 in the
# evening, 0 at bedtime, for months.
#
# A watchdog that "healed" that every night would fight the user nightly until
# he learned to ignore it — which is exactly how NIX-135's UPS ended up muted
# and then ran broken for seven weeks unnoticed. An alarm you learn to ignore
# is not an alarm.
#
# So this is NOT a threshold check. It is a RECONCILIATION LOOP:
#
#     desired (last volume the user commanded)   vs   actual (VLC right now)
#
#     desired 0   / actual 0     -> healthy. He muted it on purpose.
#     desired 512 / actual 512   -> healthy.
#     desired 512 / actual 0     -> FAULT. VLC restarted and lost it. Re-push.
#
# User intent is the reference. The watchdog can never override a deliberate
# choice, and can never mistake one for a fault. `desired` is recorded by
# mqtt-volume-control (see configuration.nix) the moment a button is pressed.
#
# THE FAILURE THAT ACTUALLY MATTERS
# =================================
# It is NOT "monitor silent at 3am while the door is open" — that is fine and
# intended. It is: door closed, button pressed, volume command accepted by
# VLC's telnet interface (which reports a cheerful `audio volume: 512`) while
# VLC's PipeWire client is orphaned — so NO SOUND COMES OUT and the parents
# believe the monitor is on. That is the 2026-07-12 failure exactly.
#
# Therefore the audio-PATH checks run unconditionally, even while muted: the
# path must be provably ready to carry sound BEFORE it is needed. Verified on
# 2026-07-13 that VLC keeps decoding audio at volume 0 (`audio decoded` still
# advances), so these checks do not false-positive while muted.
#
# WHAT IS ACTUALLY MEASURED (no proxies, no "a process exists")
# ============================================================
#   VLC alive          pgrep on --telnet-password= (NOT `pgrep -x vlc`: NixOS
#                      wraps the binary, the process is `.vlc-wrapped`; and NOT
#                      `pkill -f vlc`, which would also match the
#                      mqtt-volume-control listener's "kiosk-vlc-volume" cmdline)
#   video flowing      `video decoded` counter ADVANCES between two samples
#   audio flowing      `audio decoded` counter ADVANCES between two samples
#   audio path intact  VLC has a live PipeWire sink-input
#   intent honoured    VLC's volume == last commanded volume
#
# The decoder counters are the real liveness signal. VLC's `get_time` is
# useless here (it returns 0 for a live RTSP stream) and `state playing` can
# stay "playing" while the picture is frozen on a dead session — but a stalled
# decoder cannot lie.
{
  pkgs,
  lib,
  ...
}:
let
  stateDir = "/var/lib/babycam-watchdog";
  desiredFile = "${stateDir}/desired-volume";

  # The kiosk session's PipeWire/PulseAudio lives here (uid 1001 = kiosk).
  kioskRuntimeDir = "/run/user/1001";

  # The canonical kiosk launcher, Home-Manager-managed from
  # hosts/hsb1/files/kiosk-autostart.sh. Re-running it IS the recovery: it kills
  # the old VLC and starts a fresh one. Deliberately reused rather than
  # reimplemented, so there is exactly one definition of how the babycam starts.
  launcher = "/home/kiosk/.config/openbox/autostart";

  # The launcher's shebang is `#!/bin/bash`, which does not exist on NixOS, so
  # it must be invoked as an ARGUMENT to a real bash rather than executed.
  bashBin = lib.getExe pkgs.bash;

  # Fail toward AUDIBLE. If we have never seen a command (fresh state dir),
  # assume the monitor is meant to make noise. A wrong "loud" is an annoyance;
  # a wrong "silent" is the entire reason this ticket exists.
  defaultVolume = "512";

  # VLC's volume scale is 0-512 and it stores it as a float, so a round-trip
  # can come back off by one or two. Compare with a tolerance, or an odd
  # desired value would read as permanent "drift" and heal-loop forever.
  volumeTolerance = "5";

  sinkName = "alsa_output.pci-0000_00_1b.0.analog-stereo";

  watchdog = pkgs.writeShellApplication {
    name = "babycam-watchdog";
    runtimeInputs = with pkgs; [
      procps # pgrep
      pulseaudio # pactl
      # netcat-openbsd, NOT `pkgs.netcat` (= libressl's nc). Both connect and
      # both SEND fine — which is why mqtt-volume-control has used pkgs.netcat
      # happily for years; it never reads a reply. But libressl's nc tears the
      # socket down on stdin EOF instead of half-closing, so VLC's RESPONSE is
      # never read back. This probe is the first code here that needs the reply,
      # and with libressl's nc it saw silence and mis-reported a perfectly
      # healthy VLC as VLC_UNRESPONSIVE — then "healed" it. (Caught 2026-07-13
      # on the first deploy.)
      netcat-openbsd # VLC telnet
      mosquitto # mosquitto_pub
      systemd # systemd-run, for launching VLC outside our own cgroup
      gawk
      gnused
      gnugrep
      coreutils
      util-linux # logger
    ];
    text = ''
      export XDG_RUNTIME_DIR="${kioskRuntimeDir}"
      # Needed by `pactl` to find the kiosk's PipeWire, and by `systemd-run
      # --user` to reach the kiosk's user manager. A system service started with
      # User=kiosk gets neither of these for free.
      export DBUS_SESSION_BUS_ADDRESS="unix:path=${kioskRuntimeDir}/bus"

      log() { logger -t babycam-watchdog "$*"; }

      # --- VLC telnet ----------------------------------------------------------
      # Each argument is one telnet command. The password is piped in from a
      # subshell via printf — a bash BUILTIN, so it never appears in any
      # process's argv (/proc/<pid>/cmdline) and never reaches the journal.
      # `quit` is appended so VLC closes the connection itself and nc exits at
      # once, whichever netcat flavour is on PATH.
      vlc_q() {
        local cmds="" c
        for c in "$@"; do
          cmds="$cmds$c"$'\n'
        done
        (
          set -a
          # shellcheck source=/dev/null  # agenix-materialized, absent at lint time
          . /run/agenix/hsb1-tapo-c210-env
          set +a
          printf '%s\n%squit\n' "$TAPO_C210_PASSWORD" "$cmds" \
            | timeout 8 nc localhost 4212 2>/dev/null
        )
      }

      VLC_STATE=""
      ACTUAL=""
      VDEC1=0
      ADEC1=0
      VDEC2=0
      ADEC2=0
      SINK_INPUT=false
      SINK_STATE="unknown"

      # --- probe ---------------------------------------------------------------
      # A missing runtime dir during boot is normal; the timer's OnBootSec grace
      # covers that. Still missing afterwards means the kiosk session is dead.
      if [ ! -d "${kioskRuntimeDir}" ]; then
        HEALTH=SESSION_DEAD
      elif ! pgrep -f -- '--telnet-password=' >/dev/null 2>&1; then
        HEALTH=VLC_DEAD
      else
        HEALTH=OK

        # Two samples, 4s apart. The DELTA between them is what proves the
        # stream is genuinely moving rather than merely connected.
        FIRST="$(vlc_q status stats || true)"
        sleep 4
        SECOND="$(vlc_q stats || true)"

        VLC_STATE="$(sed -n 's/.*( state \([a-z]*\) ).*/\1/p' <<<"$FIRST" | head -1)"
        ACTUAL="$(sed -n 's/.*( audio volume: \([0-9]*\) ).*/\1/p' <<<"$FIRST" | head -1)"
        VDEC1="$(sed -n 's/.*video decoded *: *\([0-9]*\).*/\1/p' <<<"$FIRST" | head -1)"
        ADEC1="$(sed -n 's/.*audio decoded *: *\([0-9]*\).*/\1/p' <<<"$FIRST" | head -1)"
        VDEC2="$(sed -n 's/.*video decoded *: *\([0-9]*\).*/\1/p' <<<"$SECOND" | head -1)"
        ADEC2="$(sed -n 's/.*audio decoded *: *\([0-9]*\).*/\1/p' <<<"$SECOND" | head -1)"

        if pactl list sink-inputs 2>/dev/null | grep -q 'application.id = "org.VideoLAN.VLC"'; then
          SINK_INPUT=true
        fi

        # Telemetry only, never a fault on its own: PipeWire may legitimately
        # suspend an idle sink, and a sink that is genuinely gone already shows
        # up as AUDIO_DEAD through the sink-input check above.
        SINK_STATE="$(pactl list sinks 2>/dev/null \
          | awk -v s='${sinkName}' '/^Sink #/{st=""} /State:/{st=$2} /Name:/{if ($2==s) print st}' \
          | head -1)"
        if [ -z "$SINK_STATE" ]; then
          SINK_STATE="absent"
        fi

        # Order matters: a dead process cannot have a stale decoder, and a
        # frozen decoder makes the volume question moot.
        if [ -z "$VLC_STATE" ]; then
          HEALTH=VLC_UNRESPONSIVE            # process up, telnet not answering
        elif [ "$VLC_STATE" != "playing" ]; then
          HEALTH=VIDEO_STALE
        elif [ -z "$VDEC1" ] || [ "$VDEC1" = "$VDEC2" ]; then
          HEALTH=VIDEO_STALE                 # decoder frozen behind a live socket
        elif [ "$SINK_INPUT" != true ]; then
          HEALTH=AUDIO_DEAD                  # orphaned PipeWire client: volume commands are a LIE
        elif [ -z "$ADEC1" ] || [ "$ADEC1" = "$ADEC2" ]; then
          HEALTH=AUDIO_STALE                 # nothing being decoded from the stream
        fi
      fi

      # --- desired volume = the user's intent ----------------------------------
      # Resolved AFTER the probe on purpose, so that a first run can adopt the
      # volume VLC is already at.
      DESIRED=""
      if [ -r "${desiredFile}" ]; then
        DESIRED="$(tr -cd '0-9' < "${desiredFile}")"
      fi

      if [ -z "$DESIRED" ]; then
        # No record of intent yet — the very first run after deployment.
        #
        # ADOPT whatever VLC is currently set to rather than imposing a default:
        # if the monitor happened to be muted at this moment, forcing ${defaultVolume}
        # would UN-MUTE THE HOUSE on the first timer tick, possibly at 3am. The
        # user set the current value; that IS the intent, by definition.
        #
        # Only when VLC cannot be reached at all do we fall back to "audible",
        # because with nothing else to go on, a silent baby monitor is the
        # dangerous default and a loud one is merely annoying.
        if [ -n "$ACTUAL" ]; then
          DESIRED="$ACTUAL"
          log "no intent on record — adopting VLC's current volume ($DESIRED) as desired"
        else
          DESIRED="${defaultVolume}"
          log "no intent on record and VLC unreachable — defaulting to audible ($DESIRED)"
        fi
        echo "$DESIRED" > ${desiredFile}
      fi

      # --- reconcile intent (only meaningful once the pipeline itself is sound) --
      if [ "$HEALTH" = "OK" ]; then
        if [ -z "$ACTUAL" ] \
          || [ "$ACTUAL" -lt $((DESIRED - ${volumeTolerance})) ] \
          || [ "$ACTUAL" -gt $((DESIRED + ${volumeTolerance})) ]; then
          HEALTH=VOLUME_DRIFT                # intent not honoured — the 2026-07-12 silent killer
        fi
      fi

      # --- self-heal, with back-off --------------------------------------------
      # Back-off keeps a permanently-down camera (Scrypted offline, network gone)
      # from becoming a VLC relaunch loop: heal now, then 60s, 120s, 240s …
      # capped at 30min. Reset the instant we are healthy again.
      NOW="$(date +%s)"
      LAST_HEAL="$(cat ${stateDir}/last-heal-epoch 2>/dev/null || echo 0)"
      BACKOFF="$(cat ${stateDir}/heal-backoff 2>/dev/null || echo 0)"
      FAILS="$(cat ${stateDir}/consecutive-fails 2>/dev/null || echo 0)"
      HEALED=false

      if [ "$HEALTH" = "OK" ]; then
        echo 0 > ${stateDir}/heal-backoff
        echo 0 > ${stateDir}/consecutive-fails
        FAILS=0
      else
        FAILS=$((FAILS + 1))
        echo "$FAILS" > ${stateDir}/consecutive-fails

        if [ $((NOW - LAST_HEAL)) -ge "$BACKOFF" ]; then
          log "UNHEALTHY: $HEALTH (desired=$DESIRED actual=''${ACTUAL:-?}) — attempting self-heal"
          case "$HEALTH" in
            VOLUME_DRIFT)
              # Cheap fix: the pipeline is fine, only the number drifted. Do NOT
              # restart VLC for this — that would blank the picture for seconds
              # to correct a single integer.
              vlc_q "volume $DESIRED" >/dev/null 2>&1 || true
              ;;
            *)
              # Everything else needs the pipeline rebuilt. The launcher now
              # genuinely kills the old VLC (commit 945a7be1) instead of
              # silently no-op'ing and leaving a second, broken instance behind.
              #
              # Its output is LOGGED, not discarded. A heal that fails silently
              # is the very disease this ticket exists to cure — on the first
              # deploy the launcher failed here and `>/dev/null 2>&1 || true`
              # hid it completely, leaving "healed=true" in the journal next to
              # a VLC whose PID had plainly never changed.
              #
              # Three non-obvious things are load-bearing here:
              #
              # 1. `bash <script>`, NOT `<script>`. The launcher's shebang is
              #    `#!/bin/bash` and NIXOS HAS NO /bin/bash. Openbox runs the
              #    autostart through a shell at session start, so the bogus
              #    shebang never mattered there — but exec'ing it directly dies
              #    instantly with ENOENT. This was the real first-deploy failure.
              #
              # 2. systemd-run --user --scope. VLC must NOT be spawned inside
              #    this oneshot's cgroup: systemd tears that cgroup down when
              #    the unit finishes, so it would kill the very VLC it just
              #    started. A transient scope under the kiosk's own user manager
              #    outlives us — that is where the X session's processes belong.
              #
              # 3. An explicit PATH. The launcher calls `vlc`, `xset`, `pgrep`
              #    and `pkill` bare, expecting a login shell's PATH. A systemd
              #    service has no such thing.
              heal_rc=0
              heal_out="$(systemd-run --user --scope --collect --quiet \
                --setenv=DISPLAY=:0 \
                --setenv=PATH=/run/current-system/sw/bin \
                ${bashBin} ${launcher} 2>&1)" || heal_rc=$?
              if [ "$heal_rc" -eq 0 ]; then
                log "launcher ok: $(echo "$heal_out" | tr '\n' ' ')"
              else
                log "ERROR: launcher FAILED (exit $heal_rc): $(echo "$heal_out" | tr '\n' ' ')"
              fi
              sleep 8
              # A FRESH VLC COMES UP AT VOLUME 0. Without this line the "fix"
              # would merely convert one silent failure into another.
              vlc_q "volume $DESIRED" >/dev/null 2>&1 || true
              ;;
          esac
          HEALED=true
          echo "$NOW" > ${stateDir}/last-heal-epoch
          NEXT=$((BACKOFF * 2))
          if [ "$NEXT" -lt 60 ]; then NEXT=60; fi
          if [ "$NEXT" -gt 1800 ]; then NEXT=1800; fi
          echo "$NEXT" > ${stateDir}/heal-backoff
        else
          log "UNHEALTHY: $HEALTH — in back-off (''${BACKOFF}s), not healing this cycle"
        fi
      fi

      # --- alert decision -------------------------------------------------------
      # Alert only once a fault has SURVIVED a heal attempt (>=2 consecutive
      # failing cycles, ~2min). A blip that self-heals must stay invisible, or
      # the alarm becomes noise and gets ignored — which is how alarms die.
      ALERT=false
      if [ "$FAILS" -ge 2 ]; then
        ALERT=true
      fi

      # The sleeping-child rule (cf. the hsb0 UPS beeper, deliberately disabled
      # because it woke the boy): sound the LOUD alarm only when the monitor is
      # actually being RELIED ON.
      #   desired > 0 -> door shut, parents depend on it   -> SCREAM (Navi mp3).
      #   desired = 0 -> door open, boy audible directly   -> alert SILENTLY
      #                  (LaMetric visual + phone push). Waking the child to
      #                  report a monitor nobody is currently using is absurd.
      ALERT_SOUND=false
      if [ "$ALERT" = true ] && [ "$DESIRED" -gt 0 ]; then
        ALERT_SOUND=true
      fi

      # --- publish --------------------------------------------------------------
      # Retained, so whoever connects (Node-RED, Home Assistant) gets the current
      # truth immediately instead of waiting up to a minute for the next cycle.
      PAYLOAD="$(printf '{"health":"%s","desired_volume":%s,"actual_volume":%s,"vlc_state":"%s","video_decoded_delta":%s,"audio_decoded_delta":%s,"sink_input":%s,"sink_state":"%s","healed":%s,"alert":%s,"alert_sound":%s,"consecutive_fails":%s,"ts":%s}' \
        "$HEALTH" \
        "$DESIRED" \
        "''${ACTUAL:-0}" \
        "''${VLC_STATE:-unknown}" \
        "$(( ''${VDEC2:-0} - ''${VDEC1:-0} ))" \
        "$(( ''${ADEC2:-0} - ''${ADEC1:-0} ))" \
        "$SINK_INPUT" \
        "$SINK_STATE" \
        "$HEALED" \
        "$ALERT" \
        "$ALERT_SOUND" \
        "$FAILS" \
        "$NOW")"

      (
        set -a
        # shellcheck source=/dev/null  # agenix-materialized, absent at lint time
        . /run/agenix/hsb1-mqtt-client-env
        set +a
        mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
          -t 'home/hsb1/babycam/health' -r -m "$PAYLOAD" 2>/dev/null
      ) || log "WARN: could not publish health to MQTT"

      if [ "$HEALTH" != "OK" ]; then
        log "state=$HEALTH desired=$DESIRED actual=''${ACTUAL:-?} healed=$HEALED alert=$ALERT sound=$ALERT_SOUND fails=$FAILS"
      fi
    '';
  };
in
{
  systemd.services.babycam-watchdog = {
    description = "Babycam health watchdog (probe + self-heal + telemetry)";
    after = [
      "network.target"
      "display-manager.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe watchdog;
      User = "kiosk";
      # Bounded so a hung telnet or a wedged launcher can never leave the unit
      # running into the next tick. Worst realistic case is ~30s (two 8s telnet
      # timeouts + a 4s sample gap + an 8s post-heal settle).
      TimeoutStartSec = "120s";
      # Shared with mqtt-volume-control, which records the user's intent here.
      StateDirectory = "babycam-watchdog";
      StateDirectoryMode = "0750";
    };
  };

  systemd.timers.babycam-watchdog = {
    description = "Run the babycam health watchdog every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 3min boot grace: the kiosk X session, PipeWire and VLC all have to come
      # up first, and a cold boot must not look like a fault.
      OnBootSec = "3min";
      OnUnitActiveSec = "60s";
      AccuracySec = "5s";
      Unit = "babycam-watchdog.service";
    };
  };
}
