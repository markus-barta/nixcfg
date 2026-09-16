#!/usr/bin/env bash
# Attended agenix editor for the already-approved NIX-501 provider binding.
# Run only as EDITOR through the operator's existing edit-secret workflow.
# Never prints the protected JSON, jq diagnostics, or credential values.
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [ "$#" -ne 1 ] || [ ! -f "$1" ] || [ -L "$1" ]; then
  printf '%s\n' 'Expected one regular agenix editor file.' >&2
  exit 2
fi
command -v jq >/dev/null
candidate=$(mktemp "$(dirname -- "$1")/.aithema-provider.XXXXXX")
cleanup() {
  if [ -f "$candidate" ]; then unlink "$candidate"; fi
}
trap cleanup EXIT HUP INT TERM
if ! jq -e -f "$repo_root/scripts/nix501-paimos-provider-patch.jq" "$1" >"$candidate" 2>/dev/null; then
  printf '%s\n' 'Provider update refused: runtime prerequisites changed; review the configuration privately.' >&2
  exit 1
fi
mv -- "$candidate" "$1"
