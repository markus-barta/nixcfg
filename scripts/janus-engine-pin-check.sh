#!/usr/bin/env bash
# Read-only check of retained Janus engine releases and the retired app posture.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/janus-engine-pin-check.py" "$@"
