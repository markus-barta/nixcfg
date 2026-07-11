#!/bin/sh
set -u

RESTIC_BIN="${RESTIC_BIN:-/usr/local/bin/restic}"
JQ_BIN="${JQ_BIN:-jq}"
SSMTP_BIN="${SSMTP_BIN:-ssmtp}"

record_check_status() {
  check_status="$1"
  status_file="${PHAROS_BACKUP_STATUS_FILE:-}"
  [ -s "$status_file" ] || return 0

  now="$(date -u +%s)"
  check_state="failed"
  [ "$check_status" -ne 0 ] || check_state="passed"
  tmp_file="$(mktemp "${status_file}.tmp.XXXXXX")" || return 1
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
  if ! "$JQ_BIN" \
    --arg check_state "$check_state" \
    --argjson now "$now" \
    '
      .last_check_at = $now
      | .last_check_state = $check_state
      | if $check_state == "failed" then
          .state = "failed" | .summary = "repository check failed"
        elif .last_attempt_state == "succeeded" then
          .state = "healthy" | .summary = "last backup succeeded"
        else . end
    ' "$status_file" >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 0644 "$tmp_file"
  mv "$tmp_file" "$status_file"
}

message_file="$(mktemp)" || exit 70
trap 'rm -f "$message_file"' EXIT

echo 'Starting csb0 repository check.'
"$RESTIC_BIN" check --read-data >"$message_file" 2>&1
check_status="$?"

if [ "$check_status" -eq 0 ]; then
  result="Repository check completed successfully."
else
  result="Repository check failed with exit status ${check_status}. Review the csb0 backup service."
fi

status_write=0
record_check_status "$check_status" || status_write="$?"
if [ -n "${MAIL_TO:-}" ]; then
  {
    printf 'To: %s\n' "$MAIL_TO"
    printf 'From: %s\n' "${MAIL_FROM:-$MAIL_TO}"
    printf 'Subject: Restic repository check csb0\n\n'
    printf '%s\n' "$result"
  } | "$SSMTP_BIN" "$MAIL_TO" || printf 'Repository-check notification delivery failed.\n' >&2
fi
printf '%s\n' "$result"

[ "$check_status" -eq 0 ] || exit "$check_status"
[ "$status_write" -eq 0 ] || exit 70
exit 0
