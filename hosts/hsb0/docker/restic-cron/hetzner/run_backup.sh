#!/bin/sh
set -e

echo 'Do backup...'
MESSAGE="$(/usr/local/bin/restic "${RESTIC_BACKUP_OPTIONS}" --host hsb0 backup \
  --exclude '*/cache/*' --exclude '*.log*' \
  /backup/var/lib/AdGuardHome /backup/var/lib/ncps \
  2>&1)" || true

{
  echo To: "$MAIL_TO"
  echo From: "$MAIL_FROM"
  echo Subject: "$MAIL_SUBJECT"
  echo
  echo "Backup result:"
  echo
  echo "$MESSAGE"
} | ssmtp -v "$MAIL_TO"
