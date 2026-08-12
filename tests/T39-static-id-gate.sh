#!/usr/bin/env bash
# NIX-354 static uid/gid collision gate contract.
#
# The 2026-07 csb1 incident: the nixpkgs 26.11 bump let fish's man-completion
# support start a runtime man-cache service whose mandb user dynamically got
# gid 992; three weeks later pharos-container declared the same gid statically
# and NixOS shipped two names on one id without a word. These asserts keep the
# two halves of the fix wired: no runtime mandb user on fleet servers, and an
# activation gate that fails any switch producing a duplicate id.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="${repo}/modules/shared/static-id-gate.nix"
common="${repo}/modules/common.nix"

nix-instantiate --parse "${gate}" >/dev/null

# The gate module must keep its two halves: the eval-time declared-static
# assertion and the post-users activation scan that aborts the switch.
grep -Fq 'dupStaticUids' "${gate}"
grep -Fq 'dupStaticGids' "${gate}"
grep -Fq 'staticIdCollisionGate' "${gate}"
grep -Fq 'deps = [ "users" ]' "${gate}"
grep -Fq 'exit 1' "${gate}"
grep -Fq '/etc/passwd' "${gate}"
grep -Fq '/etc/group' "${gate}"

# Fleet wiring: common.nix imports the gate and keeps the runtime man-cache
# off — the mandb user must never come back silently (its stale id-map entry
# on csb1 still says 992, so a silent return would recreate the collision;
# the gate would then fail that switch, but prevention beats detection).
grep -Fq 'static-id-gate.nix' "${common}"
grep -Fq 'documentation.man.cache.enable = false' "${common}"
grep -Fq 'documentation.man.cache.generateAtRuntime = false' "${common}"

echo "T39 static-id-gate contract OK"
