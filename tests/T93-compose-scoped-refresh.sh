#!/usr/bin/env bash
# OPS-248 — evaluate real csb1 configurations, never build or activate them.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case "$repo_root" in
*" "* | *"#"* | *"?"*)
  echo 'T93: repository path cannot form a local Git flake URL' >&2
  exit 2
  ;;
esac

if ! git -C "$repo_root" diff --quiet HEAD -- modules/shared/compose-stack hosts/csb1/configuration.nix ||
  ! git -C "$repo_root" cat-file -e HEAD:tests/compose-refresh-eval.nix; then
  echo 'T93: commit the implementation first; no tests were run against an older revision' >&2
  exit 2
fi
revision=$(git -C "$repo_root" rev-parse HEAD)
export OPS248_FLAKE_REF="git+file://${repo_root}?rev=${revision}&shallow=1"
nix eval --no-write-lock-file --impure --json --file "$repo_root/tests/compose-refresh-eval.nix" |
  python3 -c '
import json, sys
checks = json.load(sys.stdin)
failed = [name for name, passed in checks.items() if passed is not True]
if not checks or failed:
    print("T93 FAIL: " + ", ".join(failed or ["empty check set"]), file=sys.stderr)
    sys.exit(1)
print(f"T93 ok: {len(checks)} scoped refresh checks (evaluation only)")
'
