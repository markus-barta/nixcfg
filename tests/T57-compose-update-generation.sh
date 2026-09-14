#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo}/modules/shared/compose-stack/update-transaction.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expected_a="${work}/generation-a.yml"
expected_b="${work}/generation-b.yml"
active="${work}/active.yml"
lock="${work}/compose.lock"
log="${work}/compose.log"
fake_compose="${work}/docker-compose"
project_dir="${work}/project directory"

touch "$expected_a" "$expected_b" "$log"
mkdir "$project_dir"
ln -s "$expected_a" "$active"

cat >"$fake_compose" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s' "$1"
  shift
  for arg in "$@"; do printf '|%s' "$arg"; done
  printf '\n'
} >>"$COMPOSE_LOG"
if flock -n "$COMPOSE_LOCK" true; then
  echo "compose command ran without the transaction lock" >&2
  exit 99
fi
if [[ "$*" == *"pull --quiet"* && -n "${ADVANCE_TO:-}" ]]; then
  ln -sfn "$ADVANCE_TO" "$ACTIVE_COMPOSE"
fi
EOF
chmod +x "$fake_compose"

export COMPOSE_LOG="$log" COMPOSE_LOCK="$lock" ACTIVE_COMPOSE="$active"

# A normal current-generation update preserves every compose argument and
# performs one pull followed by one converge under the transaction.
bash "$helper" "$active" "$expected_a" "$lock" 5 "$fake_compose" \
  "project name" "$project_dir" targets service-a service-b
mapfile -t calls <"$log"
[[ ${#calls[@]} -eq 2 ]]
[[ "${calls[0]}" == "-p|project name|-f|${expected_a}|--project-directory|${project_dir}|pull|--quiet|service-a|service-b" ]]
[[ "${calls[1]}" == "-p|project name|-f|${expected_a}|--project-directory|${project_dir}|up|-d" ]]

# Reproduce NIX-495: activation advances /etc while the old generation pulls.
# The second guard must refuse the stale `up`, leaving the new reconcile as the
# only process allowed to converge after it acquires this same lock.
: >"$log"
ln -sfn "$expected_a" "$active"
export ADVANCE_TO="$expected_b"
bash "$helper" "$active" "$expected_a" "$lock" 5 "$fake_compose" \
  project "" all
mapfile -t calls <"$log"
[[ ${#calls[@]} -eq 1 ]]
[[ "${calls[0]}" == "-p|project|-f|${expected_a}|pull|--quiet" ]]

# A generation already stale before lock acquisition performs no compose work.
: >"$log"
unset ADVANCE_TO
bash "$helper" "$active" "$expected_a" "$lock" 5 "$fake_compose" \
  project "" all
[[ ! -s "$log" ]]

# Missing active-generation evidence is an error rather than a silent skip.
if bash "$helper" "${work}/missing.yml" "$expected_a" "$lock" 5 \
  "$fake_compose" project "" none 2>/dev/null; then
  echo "FAIL: missing active compose file was accepted" >&2
  exit 1
fi

echo "T57 compose update generation guard OK"
