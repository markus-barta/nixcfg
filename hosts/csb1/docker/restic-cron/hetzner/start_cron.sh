#!/bin/sh
# shellcheck disable=SC2086,SC2317,SC2329  # intentional word-split on $RESTIC_BACKUP_OPTIONS; cron-invoked indirect functions
set -e

write_initial_pharos_backup_status() {
  status_file="${PHAROS_BACKUP_STATUS_FILE:-}"
  [ -n "$status_file" ] || return 0
  [ ! -s "$status_file" ] || return 0

  status_dir="$(dirname "$status_file")"
  mkdir -p "$status_dir" || return 0
  now="$(date -u +%s)"
  tmp_file="${status_file}.tmp"
  {
    printf '{\n'
    printf '  "id": "restic-cron-hetzner",\n'
    printf '  "label": "Restic Hetzner",\n'
    printf '  "engine": "restic",\n'
    printf '  "state": "unknown",\n'
    printf '  "configured": "enabled",\n'
    printf '  "summary": "backup has not reported yet",\n'
    printf '  "target_label": "off-box repository",\n'
    printf '  "repository_id": "restic-cron-hetzner",\n'
    printf '  "schedule": "daily",\n'
    printf '  "last_attempt_at": %s,\n' "$now"
    printf '  "last_attempt_state": "unknown"\n'
    printf '}\n'
  } >"$tmp_file" && mv "$tmp_file" "$status_file"
}

write_initial_pharos_backup_status

echo "${CRON_BACKUP_EXPRESSION} supervisorctl start restic_backup" | crontab -
crontab -l | {
  cat
  echo "${CRON_CLEANUP_EXPRESSION} supervisorctl start restic_cleanup"
} | crontab -
crontab -l | {
  cat
  echo "${CRON_CHECK_EXPRESSION} supervisorctl start restic_check"
} | crontab -
/usr/sbin/crond -f
