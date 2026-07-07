#!/usr/bin/env bash
# T06-janus-pharos-env-file.sh
# Description: Validate the staged Janus env-file profile for Pharos nonprod.
# Related PPM issues: PHAROS-40, JANUS-261

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/managed-env-files.toml"

need_line() {
  local expected="$1"
  if ! grep -Fxq "$expected" "$PROFILE"; then
    echo "missing expected profile line: $expected" >&2
    exit 1
  fi
}

need_line '[[env_files]]'
need_line 'id = "profile.PHAROS_NONPROD_REGISTRATION"'
need_line 'executor = "janus-run@csb1"'
need_line 'destination = "pharos-nonprod"'
need_line 'env = "PHAROS_REGISTRATION_TOKEN"'
need_line 'output = "/run/janus/env/pharos/pharos.env"'
need_line '[env_files.consumer]'
need_line 'consumer_ref = "consumer.pharos_nonprod"'
need_line 'kind = "service"'
need_line 'owner = "pharos"'
need_line 'environment = "nonprod"'
need_line 'reload = "none"'
need_line 'validation = ["pharos-registration-preflight"]'
need_line 'supports_dual_value = false'
need_line 'blast_radius = "non-production Pharos host registration only"'

secret_ref="$(awk -F'"' '/^secret_ref = / { print $2 }' "$PROFILE")"
if [[ ! "$secret_ref" =~ ^sec_[A-Za-z0-9_]+$ ]]; then
  echo "secret_ref must be an opaque sec_ reference" >&2
  exit 1
fi
if [[ "$secret_ref" == *PHAROS_REGISTRATION_TOKEN* ]]; then
  echo "secret_ref must not embed the env var name" >&2
  exit 1
fi

if grep -Eq 'Bearer |BEGIN |PRIVATE KEY|pharos_[0-9A-Fa-f]{16,}' "$PROFILE"; then
  echo "profile contains a forbidden secret-shaped literal" >&2
  exit 1
fi

echo "ok: staged Pharos Janus env-file profile is value-free"
