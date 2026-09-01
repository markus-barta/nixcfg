#!/usr/bin/env bash
# NIX-403: keep nixcfg's required T42 wiring, but let the pinned doctrine
# repository own the invariant. The caller verifies the checker's provenance;
# doctrine-check.sh owns all consumption-path discovery and comparison logic.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

checker_rel="scripts/doctrine-check.sh"
expected_url="https://github.com/inspr-at/inspr-modules.git"
expected_checker_blob="ef37a597e3100fb1704be5708a2c32cedd4ac7d5"

fail() {
  printf 'T42 doctrine checker provenance FAILED: %s\n' "$1" >&2
  exit 1
}

gitlink_entry="$(git ls-files --stage -- doctrine)"
[ -n "$gitlink_entry" ] || fail "doctrine gitlink is missing from the index"

read -r gitlink_mode doctrine_rev gitlink_stage gitlink_path <<EOF
$gitlink_entry
EOF
[ "$gitlink_mode" = "160000" ] || fail "doctrine is not a pinned gitlink"
[ "$gitlink_stage" = "0" ] || fail "doctrine gitlink is unmerged"
[ "$gitlink_path" = "doctrine" ] || fail "doctrine gitlink path was replaced"

doctrine_url="$(git config -f .gitmodules --get submodule.doctrine.url)"
[ "$doctrine_url" = "$expected_url" ] || fail "doctrine upstream URL was replaced"

source_root=""
if ! source_root="$({
  DOCTRINE_PIN_URL="$doctrine_url" DOCTRINE_PIN_REV="$doctrine_rev" \
    nix eval --quiet --raw --impure --expr '
      let
        source = builtins.fetchGit {
          url = builtins.getEnv "DOCTRINE_PIN_URL";
          rev = builtins.getEnv "DOCTRINE_PIN_REV";
          shallow = true;
        };
      in toString source
    '
} 2>/dev/null)"; then
  fail "pinned doctrine source is unavailable"
fi

checker_path="$source_root/$checker_rel"
[ ! -L "$checker_path" ] || fail "pinned checker path was replaced by a symlink"
[ -f "$checker_path" ] || fail "pinned checker is missing"
[ -x "$checker_path" ] || fail "pinned checker is not executable"
checker_blob="$(git hash-object -- "$checker_path")"
[ "$checker_blob" = "$expected_checker_blob" ] || fail "pinned checker content was replaced"

# Execute the immutable source fetched by nixcfg's indexed gitlink. No PATH
# lookup or mutable submodule checkout participates in this gate.
if bash "$checker_path" --multipath-only; then
  exit 0
else
  status=$?
fi

cat >&2 <<'EOF'
T42 doctrine equality boundary: paths consuming the same upstream must match.
A submodule-ahead split makes sessions read rules hosts do not implement yet;
a flake-input-ahead split makes hosts run capabilities sessions have not read.
EOF
exit "$status"
