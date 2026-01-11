#!/bin/sh
set -e

cleanup() {
  echo
  echo "Cleanup ${REPOSITORY}..."
  echo

  MESSAGE="$(/usr/local/bin/restic "${RESTIC_BACKUP_OPTIONS}" forget \
    --keep-last 12 \
    --keep-daily "${RESTIC_CLEANUP_KEEP_DAILY}" \
    --keep-weekly "${RESTIC_CLEANUP_KEEP_WEEKLY}" \
    --keep-monthly "${RESTIC_CLEANUP_KEEP_MONTHLY}" \
    --keep-yearly "${RESTIC_CLEANUP_KEEP_YEARLY}" \
    --prune 2>&1 | tee /dev/tty)" || true

  {
    echo To: "$MAIL_TO"
    echo From: "$MAIL_FROM"
    echo Subject: "🧽 Restic Cleanup ${REPOSITORY} (hetzner)"
    echo
    echo "Cleanup result:"
    echo
    echo "$MESSAGE"
  } | ssmtp "$MAIL_TO"
}

# cleanup repository
export REPOSITORY=miniserver24
cleanup
