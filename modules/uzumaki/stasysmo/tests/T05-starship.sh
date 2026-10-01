#!/usr/bin/env bash
# NIX-604: deterministic, isolated assertions (no dependency on a live daemon).
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
exec bash "$repo_root/tests/T91-stasysmo.sh" --suite layout
