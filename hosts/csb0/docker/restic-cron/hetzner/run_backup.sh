#!/bin/sh
set -u

RESTIC_BIN="${RESTIC_BIN:-/usr/local/bin/restic}"
JQ_BIN="${JQ_BIN:-jq}"
SSMTP_BIN="${SSMTP_BIN:-ssmtp}"

write_pharos_backup_status() {
  restic_status="$1"
  message_file="$2"
  status_file="${PHAROS_BACKUP_STATUS_FILE:-}"
  [ -n "$status_file" ] || return 0

  status_dir="$(dirname "$status_file")"
  mkdir -p "$status_dir" || return 1
  now="$(date -u +%s)"
  state="failed"
  summary="restic backup failed"
  run_state="failed"

  if [ "$restic_status" -eq 0 ]; then
    state="healthy"
    summary="last backup succeeded"
    run_state="succeeded"
  elif tr '[:upper:]' '[:lower:]' <"$message_file" | grep -q 'lock'; then
    state="warning"
    summary="restic repository locked"
  elif tr '[:upper:]' '[:lower:]' <"$message_file" | grep -Eq \
    'unable to open config file|repository does not exist|no repository'; then
    state="missing"
    summary="restic repository missing"
  elif tr '[:upper:]' '[:lower:]' <"$message_file" | grep -Eq \
    'password|authentication|permission denied'; then
    summary="restic authentication failed"
  fi

  last_success="null"
  last_check_at="null"
  last_check_state=""
  if [ -s "$status_file" ]; then
    previous_success="$($JQ_BIN -er '.last_success_at | select(type == "number")' "$status_file" 2>/dev/null)" || previous_success=""
    previous_check_at="$($JQ_BIN -er '.last_check_at | select(type == "number")' "$status_file" 2>/dev/null)" || previous_check_at=""
    previous_check_state="$($JQ_BIN -er '.last_check_state | select(type == "string")' "$status_file" 2>/dev/null)" || previous_check_state=""
    [ -z "$previous_success" ] || last_success="$previous_success"
    [ -z "$previous_check_at" ] || last_check_at="$previous_check_at"
    last_check_state="$previous_check_state"
  fi
  if [ "$restic_status" -eq 0 ]; then
    last_success="$now"
    if [ "$last_check_state" = "failed" ]; then
      state="failed"
      summary="repository check failed"
    fi
  fi

  tmp_file="$(mktemp "${status_file}.tmp.XXXXXX")" || return 1
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not the shell.
  if ! "$JQ_BIN" -n \
    --arg state "$state" \
    --arg summary "$summary" \
    --arg run_state "$run_state" \
    --arg last_check_state "$last_check_state" \
    --argjson now "$now" \
    --argjson last_success "$last_success" \
    --argjson last_check_at "$last_check_at" \
    '({
      id: "restic-cron-hetzner",
      label: "Restic Hetzner",
      engine: "restic",
      state: $state,
      configured: "enabled",
      summary: $summary,
      target_label: "off-box repository",
      repository_id: "restic-cron-hetzner",
      schedule: "daily",
      last_attempt_at: $now,
      last_attempt_state: $run_state
    }
    + (if $last_success == null then {} else {last_success_at: $last_success} end)
    + (if $last_check_at == null then {} else {last_check_at: $last_check_at} end)
    + (if $last_check_state == "" then {} else {last_check_state: $last_check_state} end))' \
    >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 0644 "$tmp_file"
  mv "$tmp_file" "$status_file"
}

send_report() {
  result="$1"
  [ -n "${MAIL_TO:-}" ] || return 0
  {
    printf 'To: %s\n' "$MAIL_TO"
    printf 'From: %s\n' "${MAIL_FROM:-$MAIL_TO}"
    printf 'Subject: %s\n\n' "${MAIL_SUBJECT:-Restic backup report}"
    printf '%s\n' "$result"
  } | "$SSMTP_BIN" "$MAIL_TO"
}

message_file="$(mktemp)" || exit 70
trap 'rm -f "$message_file"' EXIT

echo 'Starting csb0 backup.'
"$RESTIC_BIN" backup --host csb0 \
  --exclude '*/cache/*' --exclude '*.log*' \
  /backup/var/lib/docker/volumes /backup/home /backup/root /backup/etc \
  >"$message_file" 2>&1
restic_status="$?"

if [ "$restic_status" -eq 0 ]; then
  result="Backup completed successfully."
else
  result="Backup failed with exit status ${restic_status}. Review the csb0 backup service."
fi

status_write=0
write_pharos_backup_status "$restic_status" "$message_file" || status_write="$?"
send_report "$result" || printf 'Backup notification delivery failed.\n' >&2
printf '%s\n' "$result"

[ "$restic_status" -eq 0 ] || exit "$restic_status"
[ "$status_write" -eq 0 ] || exit 70
exit 0
