#!/bin/bash
#
# Kiosk Autostart Script
# ======================
# Purpose:
#   - Disable screen blanking / power saving
#   - Load environment secrets (camera credentials, etc.)
#   - Configure audio sink and volume
#   - Launch VLC in kiosk mode (fullscreen RTSP stream, no OSD/UI)
#
# Notes:
#   - Designed for NixOS kiosk user session
#   - Uses PipeWire/PulseAudio for audio control
#   - VLC 3.0.21+ compatible
#   - Environment variables (e.g. MINISERVER24_IP, TAPO_C210_PASSWORD)
#     are sourced from /run/agenix/hsb1-tapo-c210-env
#
# Declarative (NIX-158): this file is Home-Manager managed for the kiosk user
# (home.file ".config/openbox/autostart"). Edit it here in nixcfg, not on the host.
#
# Author: Markus (maintained with AI assistance)
# Last updated: 2026-11-04 (OPS-558: private VLC control credentials)
#

### --- SAFETY: CLEANUP OLD PROCESSES --------------------------------------

# Kill any existing VLC instances to avoid duplicates when re-running script.
#
# Match the non-secret window-title marker: NixOS wraps VLC as .vlc-wrapped,
# and a broad "vlc" match would also kill the MQTT volume-control listener.
# The legacy password flag is ONLY a cut-over cleanup target, never liveness.
for pattern in '--video-title=hsb1-kiosk-babycam( |$)' '--telnet-password='; do
  if pgrep -u kiosk -f -- "$pattern" >/dev/null; then
    echo "[INFO] Killing old VLC process(es)..."
    pkill -9 -u kiosk -f -- "$pattern"
    # Let the port/GPU free up before starting the replacement.
    for _ in $(seq 1 20); do
      pgrep -u kiosk -f -- "$pattern" >/dev/null || break
      sleep 0.2
    done
  fi
done

### --- DISPLAY / POWER MANAGEMENT -----------------------------------------

# Disable screen blanking, DPMS (energy saving), and screen saver
xset s off     # Disable screen saver
xset -dpms     # Disable DPMS (Energy Star) features
xset s noblank # Prevent screen from blanking

### --- ENVIRONMENT VARIABLES ----------------------------------------------

# Load environment variables (camera IP, password, etc.)
# set -a ensures all sourced vars are exported automatically
set -a
# shellcheck source=/dev/null  # agenix-materialized env, absent at lint time
source /run/agenix/hsb1-tapo-c210-env
set +a
# VLC control now has its own credential; do not pass the camera password to it.
unset TAPO_C210_PASSWORD

# Ensure proper runtime dir for kiosk user (needed for PipeWire/PulseAudio)
export XDG_RUNTIME_DIR=/run/user/1001

### --- WAIT FOR THE CAMERA STREAM AT BOOT (OPS-525) -----------------------

# The kiosk session opens before Docker has started Scrypted, whose rebroadcast
# answers about 20s later. Starting VLC earlier only produces connection errors.
#
# Ask for a real RTSP answer: an open port alone does not mean the stream is
# being served.
#
# Bounded by UPTIME, not by a number of tries. babycam-watchdog's first tick is
# at 180s and it recovers by re-running this script, so:
#   - this wait must be over before that tick, or the watchdog sees no VLC and
#     starts a second one
#   - a re-run later than that must not wait at all, or a heal with Scrypted down
#     holds VLC off and runs into the watchdog's own start timeout
RTSP_URL="rtsp://${MINISERVER24_IP}:35067/9726ad778d503184"
RTSP_WAIT_UNTIL_UPTIME=170

while :; do
  read -r uptime_s _ </proc/uptime
  [ "${uptime_s%%.*}" -lt "$RTSP_WAIT_UNTIL_UPTIME" ] || break
  if printf 'OPTIONS %s RTSP/1.0\r\nCSeq: 1\r\n\r\n' "$RTSP_URL" |
    nc -q 1 -w 2 "$MINISERVER24_IP" 35067 2>/dev/null | grep -q '^RTSP/1.0 200'; then
    echo "[INFO] Camera stream answers (uptime ${uptime_s%%.*}s)"
    break
  fi
  sleep 2
done

### --- AUDIO CONFIGURATION ------------------------------------------------

# Define sink name for internal speakers (adjust if hardware changes)
SINK_NAME="alsa_output.pci-0000_00_1b.0.analog-stereo"

# Wait briefly to ensure PipeWire/PulseAudio is ready
sleep 2

# Set default sink to internal speakers
/run/current-system/sw/bin/pactl set-default-sink "$SINK_NAME" ||
  echo "[WARN] Internal speakers sink not found, cannot set default."

# Set volume to 100% (max). Adjust if distortion occurs.
/run/current-system/sw/bin/pactl set-sink-volume "$SINK_NAME" 100% ||
  echo "[WARN] Failed to set internal speakers volume."

### --- VIDEO / VLC CONFIGURATION ------------------------------------------

# This generated config replaces the host-only ~/.config/vlc/vlcrc. Preserve
# all nine non-default settings, particularly the monitor's audio processing.
# Neither this file nor the separate password file may be logged or inspected.
VLC_RUNTIME_DIR="$XDG_RUNTIME_DIR/kiosk-vlc"
VLC_TELNET_PASSWORD_FILE="$VLC_RUNTIME_DIR/telnet-password"
VLC_CONFIG="$VLC_RUNTIME_DIR/vlcrc"
if ! (
  set -uo pipefail
  umask 077
  mkdir -p "$VLC_RUNTIME_DIR" || exit 1
  chmod 0700 "$VLC_RUNTIME_DIR" || exit 1
  # Keep all 192 random bits using URL-safe base64, with no /, + or =.
  telnet_password=$(head -c 24 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=\n') || exit 1
  [ "${#telnet_password}" -eq 32 ] || exit 1
  printf '%s\n' "$telnet_password" >"$VLC_TELNET_PASSWORD_FILE" || exit 1
  cat >"$VLC_CONFIG" <<EOF || exit 1
alsa-gain=1.953125
compressor-rms-peak=0.512000
equalizer-preamp=20.000000
qt-privacy-ask=0
aout=any
audio-filter=equalizer:compressor
vout=any
vod-server=any
metadata-network-access=1
telnet-password=$telnet_password
telnet-host=127.0.0.1
telnet-port=4212
EOF
  chmod 0600 "$VLC_TELNET_PASSWORD_FILE" "$VLC_CONFIG"
); then
  echo "[ERROR] Could not prepare private VLC control configuration"
  exit 1
fi

# VLC launch options explained:
#   --intf=dummy           -> No Qt interface (OPS-525): no error dialog over the
#                             camera, no empty main window that can sit above the
#                             video. The video window is the only window VLC opens,
#                             and telnet below stays the way in.
#   --no-keyboard-events   -> Prevent accidental keypresses from controlling VLC
#   --fullscreen           -> Start in fullscreen mode
#   --no-osd               -> Disable on-screen display (volume, play icons, etc.)
#   --no-video-title-show  -> Don't show stream title overlay
#   --video-on-top         -> Keep VLC window always on top
#   --loop                 -> Loop stream continuously
#   --rtsp-tcp             -> Use TCP for RTSP (more stable behind NAT/firewalls)
#   --network-caching=500  -> Buffering in ms (tune for latency vs. stability)
#   --extraintf=telnet     -> Enable telnet control interface
#   --config=...          -> Private generated settings, password and loopback bind
#   --video-title=...     -> Harmless window title used to identify this VLC
#
# Run VLC in background (&)

vlc \
  --intf=dummy \
  --no-keyboard-events \
  --fullscreen \
  --no-osd \
  --no-video-title-show \
  --video-on-top \
  --loop \
  --rtsp-tcp \
  --network-caching=500 \
  --extraintf=telnet \
  --config="$VLC_CONFIG" \
  --video-title=hsb1-kiosk-babycam \
  "$RTSP_URL" &

### --- RESTORE THE USER'S VOLUME (NIX-151) --------------------------------
#
# A FRESH VLC ALWAYS COMES UP AT VOLUME 0. The `pactl set-sink-volume` above
# sets the SINK to 100%, which is a different thing entirely: VLC's own audio
# stream still starts silent, and nothing else re-pushes it.
#
# Without this block the babycam is SILENT after every boot until the watchdog
# notices the drift — a ~4 minute window (3min boot grace + a 60s tick). It does
# self-correct, but a baby monitor that comes up mute and stays mute for four
# minutes is precisely the class of failure NIX-151 exists to eliminate. Fix it
# at the source instead of relying on the safety net.
#
# `desired-volume` is the user's INTENT, written by mqtt-volume-control every
# time the button is pressed. Honour it: if he deliberately muted the babycam
# (door open, boy audible directly), a reboot must NOT un-mute the house. Only
# when there is no record at all do we default to audible, because with nothing
# to go on a silent baby monitor is the dangerous default.
DESIRED_VOLUME=512
if [ -r /var/lib/babycam-watchdog/desired-volume ]; then
  d=$(tr -cd '0-9' </var/lib/babycam-watchdog/desired-volume)
  [ -n "$d" ] && DESIRED_VOLUME="$d"
fi

# Wait for VLC to actually hold an input before pushing volume — a VLC that is
# still negotiating RTSP answers telnet but reports nothing, and a volume set
# on a not-yet-loaded input does not stick.
#
# NOTE: never send `quit` here. VLC reads the whole burst at once, QUEUES the
# reply, then closes on `quit` before flushing it — you get the banner and
# nothing else. `nc -q 2` lingers after EOF so the reply actually arrives.
if ! { [ -r "$VLC_TELNET_PASSWORD_FILE" ] &&
  IFS= read -r vlc_password <"$VLC_TELNET_PASSWORD_FILE" &&
  [ -n "$vlc_password" ]; }; then
  echo "[WARN] VLC telnet password missing or unreadable — watchdog will reconcile"
  exit 1
fi

for _ in $(seq 1 30); do
  sleep 1
  if printf '%s\nstatus\n' "$vlc_password" |
    nc -q 2 127.0.0.1 4212 2>/dev/null | grep -q '( state '; then
    break
  fi
done

printf '%s\nvolume %s\n' "$vlc_password" "${DESIRED_VOLUME}" |
  nc -q 2 127.0.0.1 4212 >/dev/null 2>&1 &&
  echo "[INFO] Restored VLC volume to ${DESIRED_VOLUME} (user intent)" ||
  echo "[WARN] Could not restore VLC volume — watchdog will reconcile within ~60s"

### --- END OF SCRIPT ------------------------------------------------------

# Optional: log startup success
echo "[INFO] Kiosk autostart script executed successfully at $(date)"
