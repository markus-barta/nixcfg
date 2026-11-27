#!/usr/bin/env bash
# OPS-737: scoped offline evaluation, actual marker writers, and must-fail mutants.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 "${repo}/tests/test_aeon_operator_mac.py"
