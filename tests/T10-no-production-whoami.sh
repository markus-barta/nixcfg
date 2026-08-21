#!/usr/bin/env bash
# T10-no-production-whoami.sh
# Description: Keep legacy public whoami diagnostics out of production state.
# Related PPM issue: NIX-292
#
# OPS-188: this test guarded two docker-compose.yml files that OPS-127 deleted.
# `grep` exited 2 (no such file), the `if` swallowed it as "no match", and the
# test printed ok for months — it could not have failed. Targets are now the
# live compose specs, and a missing target is a failure rather than a pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

targets=(
  "$REPO_ROOT/hosts/csb0/docker/compose-spec.nix"
  "$REPO_ROOT/hosts/csb1/docker/compose-spec.nix"
  "$REPO_ROOT/infrastructure/cloudflare/dns-barta-cm.md"
  "$REPO_ROOT/hosts/csb1/docs/RUNBOOK.md"
)

for target in "${targets[@]}"; do
  if [[ ! -f "$target" ]]; then
    echo "T10: guarded file is missing: ${target#"$REPO_ROOT"/} -- repoint this test" >&2
    exit 1
  fi
done

# Historical migration snapshots under hosts/*/migrations/ are a record of what
# WAS deployed and are deliberately not scanned.
if grep -Eiq 'containous/whoami|^[[:space:]]+whoami:|whoami[01]\.barta\.cm' "${targets[@]}"; then
  echo "legacy public whoami diagnostic remains in production configuration" >&2
  grep -EinH 'containous/whoami|^[[:space:]]+whoami:|whoami[01]\.barta\.cm' "${targets[@]}" >&2 || true
  exit 1
fi

echo "ok: production compose specs and DNS documentation contain no legacy whoami service"
