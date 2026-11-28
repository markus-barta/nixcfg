#!/usr/bin/env bash
# OPS-754: pinned offline evaluation and real activation in temporary homes.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
# The Python test invokes constant "bash"; resolve it to this runner's interpreter.
runner_bin="$(dirname "${BASH}")"
export PATH="${runner_bin}:${PATH}"
python3 "${repo}/tests/test_doctrine_copies.py"
