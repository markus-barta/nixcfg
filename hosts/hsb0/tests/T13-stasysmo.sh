#!/usr/bin/env bash
# StaSysMo v2 live checks; no writes and no old host-global metric files.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
exec bash "$repo_root/modules/uzumaki/stasysmo/tests/host-check.sh"
