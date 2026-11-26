#!/usr/bin/env bash
set -euo pipefail
umask 077
export GIT_TERMINAL_PROMPT=0
exec python3 -B @SOURCE@/execute.py "$@" --config @CONFIG@
