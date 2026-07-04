#!/usr/bin/env bash
# NIX-236: warm-sync gb-stack data to /srv/hsb8 while services keep running.
# Repeatable — run as often as you like to keep the copy warm; the final
# consistent delta sync happens inside nix230-cutover.sh with services stopped.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || {
  echo "run with sudo"
  exit 1
}

SRC=/home/gb/docker/mounts
DST=/srv/hsb8/mounts

mkdir -p "$DST"
rsync -aH --info=stats1 "$SRC/homeassistant/" "$DST/homeassistant/"
rsync -aH --info=stats1 "$SRC/mosquitto/" "$DST/mosquitto/"
echo "presync done: $(du -sh "$DST" | cut -f1) in $DST"
