#!/usr/bin/env bash
# Run each v2 assertion once; unittest owns the counters (safe with Bash set -e).
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$repo_root/tests/T91-stasysmo.sh" "$@"
