#!/usr/bin/env bash
# T10-no-production-whoami.sh
# Description: Keep legacy public whoami diagnostics out of production state.
# Related PPM issue: NIX-292

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CSB0_COMPOSE="$REPO_ROOT/hosts/csb0/docker/docker-compose.yml"
CSB1_COMPOSE="$REPO_ROOT/hosts/csb1/docker/docker-compose.yml"
DNS_DOC="$REPO_ROOT/infrastructure/cloudflare/dns-barta-cm.md"
CSB1_RUNBOOK="$REPO_ROOT/hosts/csb1/docs/RUNBOOK.md"

if grep -Eiq 'containous/whoami|^[[:space:]]+whoami:|whoami[01]\.barta\.cm' \
  "$CSB0_COMPOSE" "$CSB1_COMPOSE" "$DNS_DOC" "$CSB1_RUNBOOK"; then
  echo "legacy public whoami diagnostic remains in production configuration" >&2
  exit 1
fi

echo "ok: production Compose and DNS documentation contain no legacy whoami service"
