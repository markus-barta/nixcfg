#!/bin/sh
# shellcheck disable=SC2086,SC2317,SC2329  # intentional word-split on $RESTIC_BACKUP_OPTIONS; cron-invoked indirect functions
set -e

write_pharos_backup_status() {
  restic_status="$1"
  restic_message="$2"
  status_file="${PHAROS_BACKUP_STATUS_FILE:-}"
  [ -n "$status_file" ] || return 0

  status_dir="$(dirname "$status_file")"
  mkdir -p "$status_dir" || return 0
  now="$(date -u +%s)"
  run_state="failed"

  if [ "$restic_status" -eq 0 ]; then
    state="healthy"
    summary="last backup succeeded"
    run_state="succeeded"
  else
    lower_message="$(printf '%s' "$restic_message" | tr '[:upper:]' '[:lower:]')"
    if printf '%s' "$lower_message" | grep -q 'lock'; then
      state="warning"
      summary="restic repository locked"
    elif printf '%s' "$lower_message" | grep -q 'unable to open config file\|repository does not exist\|no repository'; then
      state="missing"
      summary="restic repository missing"
    elif printf '%s' "$lower_message" | grep -q 'password\|authentication\|permission denied'; then
      state="failed"
      summary="restic authentication failed"
    else
      state="failed"
      summary="restic backup failed"
    fi
  fi

  tmp_file="${status_file}.tmp"
  {
    printf '{\n'
    printf '  "id": "restic-cron-hetzner",\n'
    printf '  "label": "Restic Hetzner",\n'
    printf '  "engine": "restic",\n'
    printf '  "state": "%s",\n' "$state"
    printf '  "configured": "enabled",\n'
    printf '  "summary": "%s",\n' "$summary"
    printf '  "target_label": "off-box repository",\n'
    printf '  "repository_id": "restic-cron-hetzner",\n'
    printf '  "schedule": "daily",\n'
    printf '  "last_attempt_at": %s,\n' "$now"
    printf '  "last_attempt_state": "%s"' "$run_state"
    if [ "$restic_status" -eq 0 ]; then
      printf ',\n  "last_success_at": %s\n' "$now"
    else
      printf '\n'
    fi
    printf '}\n'
  } >"$tmp_file" && mv "$tmp_file" "$status_file"
}

echo 'Do backup...'
message_file="$(mktemp)"
set +e
/usr/local/bin/restic ${RESTIC_BACKUP_OPTIONS} --host csb1 backup \
  --exclude '*/cache/*' --exclude '*.log*' \
  /backup/var/lib/docker/volumes /backup/var/lib/csb1-docker /backup/home /backup/root /backup/etc \
  >"$message_file" 2>&1
RESTIC_STATUS="$?"
set -e
tee /dev/tty <"$message_file" || true
MESSAGE="$(cat "$message_file")"
rm -f "$message_file"

write_pharos_backup_status "$RESTIC_STATUS" "$MESSAGE"

{
  echo To: $MAIL_TO
  echo From: $MAIL_FROM
  echo Subject: $MAIL_SUBJECT
  echo
  echo "Backup result:"
  echo
  echo "$MESSAGE"
} | ssmtp -v $MAIL_TO
