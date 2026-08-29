#!/usr/bin/env bash
# nixcfg consumes the doctrine repo TWICE — the two pins must agree.
#
#   * flake input `inspr-modules` (flake.lock) renders the agent skills onto
#     hosts; it activates at `nixos-rebuild switch`.
#   * git submodule `doctrine` provides the kernel and domain packs that every
#     agent session reads; it activates at `git checkout`.
#
# WHY EQUALITY, NOT "CLOSE ENOUGH"
# ===============================
# The two have different activation moments, so a split is silent and directional:
#   submodule ahead → sessions read rules the hosts do not implement yet
#   input ahead     → hosts execute capabilities nobody has read the rules for
# Both are the declared-vs-actual class (INSPR-296). It has already happened
# twice: caught once in review (PR #374, one path moved), then again overnight
# as a three-way split (2026-08-17: input 7eab3cda, submodule 3cf1a973,
# canonical 7598d63). Neither time did anything fail.
#
# 🟡 THIS TEST IS DELIBERATELY TEMPORARY.
# Its successor is a multi-path mode in inspr-modules' own `doctrine-check.sh`,
# owned by the doctrine side: it will enumerate every consumption path a repo
# declares (submodule pins, flake inputs resolving to inspr-modules, vendored
# copies) and assert they agree, so single-path repos stay unaffected and the
# rule lives in one place. When that lands, delete the LOGIC below but KEEP the
# CI wiring, calling the upstream check from here — so nixcfg is never left with
# no assertion at all, and there is never a moment with two checks asserting one
# invariant through slightly different logic (worse than either alone). Same
# shape as T41 calling hausv-org's verify-preview.sh.
#
# 🔴 Successor ticket: INSPR-300 (owned by the doctrine side). INSPR-296 is the
# broader "no per-repo wiring assertion exists" work that 300 hangs off. Agreed
# with the doctrine/OPS session 2026-08-17.
#
# Two properties the successor must keep, learned from writing this one:
#   * read every path at the SAME staging level (see the index note below) —
#     otherwise it compares two points in time and false-fails the one person
#     it exists to help, the operator mid-bump, while passing in CI;
#   * equality applies PER UPSTREAM: a repo legitimately vendoring two
#     different upstreams must not be failed for that.
#
# Note: this is a REQUIRED gate, not informational. It runs as a step of the
# `Pharos fleet release compatibility` job, and that job is one of main's
# required contexts (with the formatting gate, CodeQL, and `Eval flake — all
# hosts`), so a red result here blocks the merge. Verify with:
#   gh api repos/markus-barta/nixcfg/branches/main/protection \
#     --jq .required_status_checks.contexts
# This comment previously claimed the opposite — that required checks were "the
# formatting gate and CodeQL only". That went stale when protection was widened,
# and on 2026-08-25 it misled a reviewing agent into recommending work to make
# this test required when it already was. A stale note about a control is worse
# than no note: it is read as current. Re-check the API output above before
# editing this paragraph.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo}"

input_rev="$(
  python3 -c '
import json, sys
lock = json.load(open("flake.lock"))
node = lock["nodes"].get("inspr-modules")
if not node:
    sys.exit("flake.lock has no inspr-modules input")
print(node["locked"]["rev"])'
)"

# The INDEXED pin, not the working-tree checkout: the pin is what a fresh clone
# and CI get, and a locally-drifted submodule is a separate (also real) problem.
# The index rather than HEAD, so a staged bump is validated before it is
# committed; on a CI checkout the two are identical anyway.
submodule_rev="$(git ls-files --stage doctrine | awk '{print $2}')"

if [ -z "${submodule_rev}" ]; then
  echo "FAIL: no doctrine submodule recorded in HEAD" >&2
  exit 1
fi

if [ "${input_rev}" != "${submodule_rev}" ]; then
  cat >&2 <<EOF
FAIL: nixcfg's two doctrine paths disagree.

  flake input inspr-modules : ${input_rev}
  submodule doctrine        : ${submodule_rev}

Both consume github.com/inspr-at/inspr-modules and must sit on the SAME
revision. Do not "fix" this by bumping whichever path is easier — move both:

  nix flake update inspr-modules
  git submodule update --remote doctrine
  git add flake.lock doctrine

Why it matters: the input activates at switch (host skills), the submodule at
checkout (the kernel agent sessions read). A split means one half of the fleet
follows rules the other half has not got.
EOF
  exit 1
fi

echo "T42 doctrine paths agree OK (${input_rev:0:8})"
