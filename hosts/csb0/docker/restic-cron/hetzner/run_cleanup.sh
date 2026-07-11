#!/bin/sh
set -u

RESTIC_BIN="${RESTIC_BIN:-/usr/local/bin/restic}"
SSMTP_BIN="${SSMTP_BIN:-ssmtp}"

message_file="$(mktemp)" || exit 70
trap 'rm -f "$message_file"' EXIT

echo 'Starting csb0 repository cleanup.'
"$RESTIC_BIN" forget \
  --keep-last 12 \
  --keep-daily "${RESTIC_CLEANUP_KEEP_DAILY}" \
  --keep-weekly "${RESTIC_CLEANUP_KEEP_WEEKLY}" \
  --keep-monthly "${RESTIC_CLEANUP_KEEP_MONTHLY}" \
  --keep-yearly "${RESTIC_CLEANUP_KEEP_YEARLY}" \
  --prune >"$message_file" 2>&1
cleanup_status="$?"

if [ "$cleanup_status" -eq 0 ]; then
  result="Repository cleanup completed successfully."
else
  result="Repository cleanup failed with exit status ${cleanup_status}. Review the csb0 backup service."
fi

if [ -n "${MAIL_TO:-}" ]; then
  {
    printf 'To: %s\n' "$MAIL_TO"
    printf 'From: %s\n' "${MAIL_FROM:-$MAIL_TO}"
    printf 'Subject: Restic repository cleanup csb0\n\n'
    printf '%s\n' "$result"
  } | "$SSMTP_BIN" "$MAIL_TO" || printf 'Repository-cleanup notification delivery failed.\n' >&2
fi
printf '%s\n' "$result"
exit "$cleanup_status"
