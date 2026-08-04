#!/usr/bin/env bash
# OPS-136 — standalone manual rollback to the legacy projects. Used when
# cutover.sh is no longer running (its automatic rollback covers in-window
# failures). Safe to re-run: every step is state-checked.
#
# Consult the RUNBOOK "OPS-136 per-service state table" FIRST if the state
# is mixed (some services csb1-owned, some legacy, some absent).
# shellcheck source=hosts/csb1/docker/ops136/ops136-lib.sh disable=SC1091
source "$(dirname "$0")/ops136-lib.sh"
export OPS136_PHASE=ROLLBACK
require_root
require_binary
take_lock
journal "manual rollback invoked"
rollback_to_legacy
if route_smoke; then
  journal "rollback verified: legacy stack serving"
else
  die "legacy stack restored but route smoke FAILED — state-table recovery"
fi
journal "MANUAL ROLLBACK COMPLETE"
