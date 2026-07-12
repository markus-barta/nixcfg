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
# Last updated: 2026-07-03 (NIX-158: creds source repointed to agenix)
#

### --- SAFETY: CLEANUP OLD PROCESSES --------------------------------------

# Kill any existing VLC instances to avoid duplicates when re-running script.
#
# Match on the --telnet-password= flag (unique to this script's own vlc
# invocation), not on process name: NixOS wraps vlc so its comm/argv0 shows
# as ".vlc-wrapped", which `pgrep -x vlc` never matches — this cleanup was a
# silent no-op, and a re-run left the old (audio-dead) instance running
# while a second one failed to start (port 4212 already bound, GPU/X
# contention). Matching on process name substring "vlc" (e.g. `pkill -f
# vlc`) is unsafe here too: the mqtt-volume-control listener's own cmdline
# contains "kiosk-vlc-volume" and would get killed as collateral damage.
if pgrep -f -- '--telnet-password=' >/dev/null; then
  echo "[INFO] Killing old VLC process(es)..."
  pkill -9 -f -- '--telnet-password='
  # Wait for the port/GPU to actually free up rather than a flat sleep —
  # starting a new vlc before the old one fully exits recreates the same
  # duplicate-instance failure this cleanup exists to prevent.
  for _ in $(seq 1 20); do
    pgrep -f -- '--telnet-password=' >/dev/null || break
    sleep 0.2
  done
fi

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

# Ensure proper runtime dir for kiosk user (needed for PipeWire/PulseAudio)
export XDG_RUNTIME_DIR=/run/user/1001

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

# VLC launch options explained:
#   --no-keyboard-events   -> Prevent accidental keypresses from controlling VLC
#   --fullscreen           -> Start in fullscreen mode
#   --no-osd               -> Disable on-screen display (volume, play icons, etc.)
#   --no-video-title-show  -> Don't show stream title overlay
#   --no-embedded-video    -> Force standalone video window
#   --video-on-top         -> Keep VLC window always on top
#   --loop                 -> Loop stream continuously
#   --rtsp-tcp             -> Use TCP for RTSP (more stable behind NAT/firewalls)
#   --network-caching=500  -> Buffering in ms (tune for latency vs. stability)
#   --extraintf=telnet     -> Enable telnet control interface
#   --telnet-password=...  -> Password for telnet interface
#
# RTSP URL is built from environment variables:
#   rtsp://${MINISERVER24_IP}:35067/9726ad778d503184
#
# Run VLC in background (&)

vlc \
  --no-keyboard-events \
  --fullscreen \
  --no-osd \
  --no-video-title-show \
  --no-embedded-video \
  --video-on-top \
  --loop \
  --rtsp-tcp \
  --network-caching=500 \
  --extraintf=telnet \
  --telnet-password="${TAPO_C210_PASSWORD}" \
  "rtsp://${MINISERVER24_IP}:35067/9726ad778d503184" &

### --- END OF SCRIPT ------------------------------------------------------

# Optional: log startup success
echo "[INFO] Kiosk autostart script executed successfully at $(date)"
