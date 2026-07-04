#!/usr/bin/env bash
# NIX-237 rollback: return to the gb stack. Data in /home/gb/docker/mounts is
# never touched by the cutover, so this is safe at any point after it.
# Only the three migrated services are removed from the managed stack —
# fleetcom-agent and pharos-beacon keep running.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || {
  echo "run with sudo"
  exit 1
}

REPO=/home/mba/Code/nixcfg/hosts/hsb8/docker/docker-compose.yml

rm -f /srv/hsb8/.cutover-done # disarm hsb8-stack.service again
docker compose -p docker -f "$REPO" rm -sf homeassistant mosquitto watchtower || true
docker compose -p docker -f /home/gb/docker/docker-compose.yml up -d

echo "rolled back to gb stack. /srv/hsb8 data left in place for analysis."
