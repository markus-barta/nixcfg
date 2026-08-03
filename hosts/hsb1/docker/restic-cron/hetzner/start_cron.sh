#!/bin/sh
set -u

write_initial_pharos_backup_status() {
  status_file="${PHAROS_BACKUP_STATUS_FILE:-}"
  [ -n "$status_file" ] || return 0
  [ ! -s "$status_file" ] || return 0

  status_dir="$(dirname "$status_file")"
  mkdir -p "$status_dir" || return 1
  now="$(date -u +%s)"
  tmp_file="$(mktemp "${status_file}.tmp.XXXXXX")" || return 1
  if ! jq -n --argjson now "$now" '{
    id: "restic-cron-hetzner",
    label: "Restic Hetzner",
    engine: "restic",
    state: "unknown",
    configured: "enabled",
    summary: "backup has not reported yet",
    target_label: "off-box repository",
    repository_id: "restic-cron-hetzner",
    schedule: "daily",
    last_attempt_at: $now,
    last_attempt_state: "unknown"
  }' >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 0644 "$tmp_file"
  mv "$tmp_file" "$status_file"
}

write_initial_pharos_backup_status || exit 70

{
  printf '%s supervisorctl start restic_backup\n' "$CRON_BACKUP_EXPRESSION"
  printf '%s supervisorctl start restic_cleanup\n' "$CRON_CLEANUP_EXPRESSION"
  printf '%s supervisorctl start restic_check\n' "$CRON_CHECK_EXPRESSION"
} | crontab -

exec /usr/sbin/crond -f
