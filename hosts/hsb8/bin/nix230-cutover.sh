#!/usr/bin/env bash
# NIX-237: cutover gb stack -> managed stack. HA is offline between "stopping
# gb stack" and the HA-UI check (~2-5 min with a warm presync).
# Preconditions: NIX-235 agenix secret deployed (just switch ran on this
# host), nix230-presync.sh run at least once recently.
# Rollback: nix230-rollback.sh (gb stack + data stay untouched).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || {
  echo "run with sudo"
  exit 1
}

GB=/home/gb/docker/docker-compose.yml
REPO=/home/mba/Code/nixcfg/hosts/hsb8/docker/docker-compose.yml

[ -f /run/agenix/hsb8-watchtower-env ] || {
  echo "ABORT: /run/agenix/hsb8-watchtower-env missing (NIX-235 + nixos switch first)"
  exit 1
}
[ -d /srv/hsb8/mounts/homeassistant ] || {
  echo "ABORT: presync never ran (nix230-presync.sh)"
  exit 1
}

echo "== stopping gb stack (HA offline from here) — $(date)"
docker compose -p docker -f "$GB" down

echo "== final delta sync (services stopped, consistent)"
rsync -aH --delete /home/gb/docker/mounts/homeassistant/ /srv/hsb8/mounts/homeassistant/
rsync -aH --delete /home/gb/docker/mounts/mosquitto/ /srv/hsb8/mounts/mosquitto/

echo "== starting managed stack"
docker compose -p docker -f "$REPO" up -d

echo "== waiting for HA UI (max 5 min)"
code=000
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8123/ || true)
  [ "$code" = "200" ] && break
  sleep 5
done
[ "$code" = "200" ] || {
  echo "WARN: HA UI not up after 5 min — check: docker logs homeassistant"
  echo "Rollback available: nix230-rollback.sh"
  exit 1
}

echo "== HA UI 200 — $(date)"
docker logs watchtower --tail 10 2>&1 | grep -i "Scheduling first run" ||
  echo "WARN: watchtower shows no schedule line — check: docker logs watchtower"

touch /srv/hsb8/.cutover-done
echo "== cutover done. Marker /srv/hsb8/.cutover-done set (arms hsb8-stack.service)."
echo "Manual checks left: mosquitto clients reconnect, bosun 'Update agent' button,"
echo "HA integrations healthy. Then: NIX-238 (retire gb compose after soak)."
