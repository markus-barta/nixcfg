#!/usr/bin/env bash
# OPS-754: pinned offline evaluation and real activation in temporary homes.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export OPS754_TEST_BASH="${BASH}"
python3 "${repo}/tests/test_doctrine_copies.py"
