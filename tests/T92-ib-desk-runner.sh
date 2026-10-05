#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/modules/ib-desk-runner/default.nix"
runner="$repo_root/modules/ib-desk-runner/runner.mjs"
ib="$repo_root/modules/ib-desk-runner/ib.mjs"
host="$repo_root/hosts/hsb0/configuration.nix"
docs="$repo_root/hosts/hsb0/docs/IB-DESK-RUNNER.md"

node --test "$repo_root/modules/ib-desk-runner/policy.test.mjs"

grep -Fq 'IB_DESK_GATEWAY_PORT=4002' "$module"
grep -Fq 'TRADING_MODE=paper' "$module"
grep -Fq 'ConditionPathExists' "$module"
grep -Fq 'joel-ib-paper-flatten-own' "$module"
grep -Fq 'OnCalendar = "Mon..Fri *-*-* 21:50:00 Europe/Vienna"' "$module"
grep -Fq 'activeHalt' "$runner"
grep -Fq 'orderRef: intent.intentId' "$ib"
grep -Fq 'KEEP.includes' "$ib"
grep -Fq '../../modules/ib-desk-runner' "$host"
grep -Fq 'barta.paper-desk-intent.v1' "$docs"

if grep -Fq 'globalCancel' "$repo_root/modules/ib-desk-runner/"*.mjs; then
  printf 'T92 failed: runner must never use globalCancel\n' >&2
  exit 1
fi

printf 'T92 passed: paper pull runner brakes, ownership and declarative timer are wired\n'
