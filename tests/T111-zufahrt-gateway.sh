#!/usr/bin/env bash
# T111 — HAUSV-916 Zufahrt gateway: unit tests plus the module's reach contract.
# Offline: no host, broker, network or flake fetching.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/modules/zufahrt-gateway"
fail() {
  echo "T111 FAIL: $*" >&2
  exit 1
}

python3 -B "$module/test_gateway.py" >/dev/null 2>&1 || {
  python3 -B "$module/test_gateway.py"
  fail "gateway unit tests"
}

# The module keeps its guards: tailnet + loopback only, no capabilities, hash-only token.
grep -qF 'IPAddressDeny = "any";' "$module/default.nix" || fail "IPAddressDeny any missing"
grep -qF '"100.64.0.0/10"' "$module/default.nix" || fail "tailnet allow missing"
grep -qF 'CapabilityBoundingSet = "";' "$module/default.nix" || fail "capabilities not dropped"
# shellcheck disable=SC2016 # a literal Nix interpolation, not a shell expansion
grep -qF '"token-sha256:${cfg.tokenHashFile}"' "$module/default.nix" || fail "token hash credential missing"
# Only the two fixed actions exist, and the gate command is never retained.
grep -qF 'ACTIONS = ("/zufahrt", "/zufahrt5")' "$module/gateway.py" || fail "action list changed"
grep -qF 'bytes([0x32])' "$module/gateway.py" || fail "publish must be QoS 1 with retain 0 (0x32)"
if grep -nE 'bytes\(\[0x3[13]\]\)' "$module/gateway.py"; then fail "a retained publish appeared"; fi
echo "zufahrt_gateway=ok"
