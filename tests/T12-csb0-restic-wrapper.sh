#!/usr/bin/env bash
# Description: Keep csb0 Restic execution fail-fast and its Pharos status truthful.
# Related PPM issue: NIX-294

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose="$repo_root/hosts/csb0/docker/docker-compose.yml"
backup_script="$repo_root/hosts/csb0/docker/restic-cron/hetzner/run_backup.sh"
check_script="$repo_root/hosts/csb0/docker/restic-cron/hetzner/run_check.sh"
cleanup_script="$repo_root/hosts/csb0/docker/restic-cron/hetzner/run_cleanup.sh"
supervisor="$repo_root/hosts/csb0/docker/restic-cron/hetzner/supervisor_restic.ini"

grep -Eq '^[[:space:]]+RESTIC_REPOSITORY:' "$compose"
if grep -q 'RESTIC_BACKUP_OPTIONS' "$compose" "$backup_script" "$check_script" "$cleanup_script"; then
  echo "packed Restic option strings are not allowed" >&2
  exit 1
fi
grep -Fq 'PHAROS_BACKUP_MODE=status-file' "$compose"
grep -Fq '/var/lib/csb0-docker/pharos-backup-status:/pharos-backup-status:ro' "$compose"
grep -Fq 'command=sh /usr/local/bin/run_backup.sh' "$supervisor"
if grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' "$backup_script"; then
  echo "run_backup.sh must not use eval" >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
cleanup() {
  find "$tmp_dir" -type f -delete
  find "$tmp_dir" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup EXIT

fake_restic="$tmp_dir/restic"
fake_ssmtp="$tmp_dir/ssmtp"
args_file="$tmp_dir/args"
status_file="$tmp_dir/status.json"

cat >"$fake_restic" <<'FAKE_RESTIC'
#!/bin/sh
printf '%s\n' "$@" >"$ARGS_FILE"
printf 'simulated restic result\n'
exit "${RESTIC_TEST_EXIT:-0}"
FAKE_RESTIC
cat >"$fake_ssmtp" <<'FAKE_SSMTP'
#!/bin/sh
while IFS= read -r _line; do :; done
exit "${MAIL_TEST_EXIT:-0}"
FAKE_SSMTP
chmod +x "$fake_restic" "$fake_ssmtp"

run_wrapper() {
  RESTIC_BIN="$fake_restic" \
    SSMTP_BIN="$fake_ssmtp" \
    JQ_BIN="$(command -v jq)" \
    ARGS_FILE="$args_file" \
    RESTIC_TEST_EXIT="$1" \
    MAIL_TEST_EXIT="$2" \
    RESTIC_REPOSITORY="test-repository" \
    PHAROS_BACKUP_STATUS_FILE="$status_file" \
    MAIL_TO="operator@example.invalid" \
    MAIL_FROM="operator@example.invalid" \
    MAIL_SUBJECT="Restic test" \
    sh "$backup_script"
}

set +e
run_wrapper 23 0 >/dev/null 2>&1
failed_status=$?
set -e
[[ "$failed_status" == 23 ]]
jq -e '.state == "failed" and .last_attempt_state == "failed"' "$status_file" >/dev/null

run_wrapper 0 71 >/dev/null 2>&1
jq -e '
  .state == "healthy"
  and .last_attempt_state == "succeeded"
  and (.last_success_at | type == "number")
' "$status_file" >/dev/null

[[ "$(sed -n '1p' "$args_file")" == "backup" ]]
if grep -Fxq -- '-r' "$args_file" || grep -Fxq -- 'test-repository' "$args_file"; then
  echo "repository configuration leaked into Restic positional arguments" >&2
  exit 1
fi

run_check_wrapper() {
  RESTIC_BIN="$fake_restic" \
    SSMTP_BIN="$fake_ssmtp" \
    JQ_BIN="$(command -v jq)" \
    ARGS_FILE="$args_file" \
    RESTIC_TEST_EXIT="$1" \
    MAIL_TEST_EXIT="$2" \
    RESTIC_REPOSITORY="test-repository" \
    PHAROS_BACKUP_STATUS_FILE="$status_file" \
    MAIL_TO="operator@example.invalid" \
    MAIL_FROM="operator@example.invalid" \
    sh "$check_script"
}

set +e
run_check_wrapper 31 0 >/dev/null 2>&1
failed_check_status=$?
set -e
[[ "$failed_check_status" == 31 ]]
jq -e '.state == "failed" and .last_check_state == "failed"' "$status_file" >/dev/null

run_check_wrapper 0 71 >/dev/null 2>&1
jq -e '.state == "healthy" and .last_check_state == "passed"' "$status_file" >/dev/null
[[ "$(sed -n '1p' "$args_file")" == "check" ]]

echo "csb0_restic_wrapper=passed"
