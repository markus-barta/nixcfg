#!/usr/bin/env bash
# NIX-604: isolated snapshots, native sampler and real fish PTY rendering.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 "$repo_root/tests/stasysmo_test.py" "$@"
