#!/usr/bin/env bash
# OPS-246 — evaluate the two cloud compose specs, never the resolved environment.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 "$repo_root/tests/compose_published_ports.py" --repo-root "$repo_root" "$@"
