#!/usr/bin/env bash
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf '%s: run this contract under Bash 5 (found %s)\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s "$repo_root/tests" -p test_janus_engine_pin_check.py -v
