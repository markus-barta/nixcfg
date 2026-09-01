#!/usr/bin/env bash
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
fake_bin="$fixture/bin"
args_file="$fixture/attic-args"
mkdir -p "$fake_bin"

cleanup() {
  find "$fixture" -type f -delete
  find "$fixture" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

nix_binary=$(realpath "$(command -v nix)")
store_path=${nix_binary%/bin/nix}
[[ "$store_path" == /nix/store/* && -e "$store_path" ]]

cat >"$fake_bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --query && "$2" == --requisites && "$3" == "$EXPECTED_STORE_PATH" ]]
[[ "${NIX_STORE_FAIL:-0}" == 0 ]] || exit 17
printf '%s\n%s-dependency\n' "$EXPECTED_STORE_PATH" "$EXPECTED_STORE_PATH"
EOF

cat >"$fake_bin/attic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$ATTIC_ARGS_FILE"
EOF
chmod +x "$fake_bin/nix-store" "$fake_bin/attic"

output=$(
  PATH="$fake_bin:$PATH" \
    EXPECTED_STORE_PATH="$store_path" \
    ATTIC_ARGS_FILE="$args_file" \
    "$repo_root/scripts/push-all-to-attic.sh" main "$store_path"
)

expected_args=$(printf '%s\n' push --ignore-upstream-cache-filter main "$store_path")
[[ "$(cat "$args_file")" == "$expected_args" ]]
[[ "$output" == *'attic_push=starting cache=main closure_paths=2'* ]]
[[ "$output" == *'attic_push=passed cache=main closure_paths=2'* ]]

if PATH="$fake_bin:$PATH" "$repo_root/scripts/push-all-to-attic.sh" '../bad' "$store_path" \
  >/dev/null 2>&1; then
  printf 'attic_current_system=failed reason=invalid_cache_accepted\n' >&2
  exit 1
fi
if PATH="$fake_bin:$PATH" "$repo_root/scripts/push-all-to-attic.sh" main "$fixture" \
  >/dev/null 2>&1; then
  printf 'attic_current_system=failed reason=non_store_path_accepted\n' >&2
  exit 1
fi

rm -f "$args_file"
if failure_output=$(
  PATH="$fake_bin:$PATH" \
    EXPECTED_STORE_PATH="$store_path" \
    ATTIC_ARGS_FILE="$args_file" \
    NIX_STORE_FAIL=1 \
    "$repo_root/scripts/push-all-to-attic.sh" main "$store_path" 2>&1
); then
  printf 'attic_current_system=failed reason=closure_query_failure_accepted\n' >&2
  exit 1
fi
[[ "$failure_output" == *'attic_push=failed reason=closure_query_failed'* ]]
[[ ! -e "$args_file" ]]

grep -Fq "push-all cache='main':" "$repo_root/justfile"
if grep -Fq 'cicinas2:nix-store' "$repo_root/justfile" "$repo_root/scripts/push-all-to-attic.sh"; then
  printf 'attic_current_system=failed reason=retired_cache_reference\n' >&2
  exit 1
fi

printf 'attic_current_system=passed closure_pushes=1 cache=main failures=fail_closed\n'
