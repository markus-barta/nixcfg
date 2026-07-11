#!/usr/bin/env bash
# T09-speedtest-tracker-secret-boundary.sh
# Description: Keep hsb0 Speedtest Tracker's application key out of tracked runtime config.
# Related PPM issue: NIX-290

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_NIX="$REPO_ROOT/secrets/secrets.nix"
SECRET_FILE="$REPO_ROOT/secrets/hsb0-speedtest-tracker-app-key.age"
HSB0_CONFIG="$REPO_ROOT/hosts/hsb0/configuration.nix"
HSB0_COMPOSE="$REPO_ROOT/hosts/hsb0/docker/docker-compose.yml"

need_line() {
  local expected="$1"
  local file="$2"
  if ! grep -Fxq "$expected" "$file"; then
    echo "missing expected line in ${file#"$REPO_ROOT"/}: $expected" >&2
    exit 1
  fi
}

need_line '  "hsb0-speedtest-tracker-app-key.age".publicKeys = markus ++ hsb0;' "$SECRETS_NIX"
need_line '  age.secrets.hsb0-speedtest-tracker-app-key = {' "$HSB0_CONFIG"
need_line '    file = ../../secrets/hsb0-speedtest-tracker-app-key.age;' "$HSB0_CONFIG"
need_line '    mode = "400";' "$HSB0_CONFIG"
need_line '      - FILE__APP_KEY=/run/secrets/speedtest-tracker-app-key' "$HSB0_COMPOSE"
need_line '      - /run/agenix/hsb0-speedtest-tracker-app-key:/run/secrets/speedtest-tracker-app-key:ro' "$HSB0_COMPOSE"

test -s "$SECRET_FILE"

if grep -Eq '(^|[[:space:]-])APP_KEY=' "$HSB0_COMPOSE"; then
  echo "Speedtest Tracker APP_KEY must not be stored inline" >&2
  exit 1
fi

if grep -q 'APP_PREVIOUS_KEYS' "$HSB0_COMPOSE"; then
  echo "The exposed Speedtest Tracker key must not remain trusted as a previous key" >&2
  exit 1
fi

echo "ok: Speedtest Tracker uses only a root-owned agenix file boundary"
