#!/bin/sh
# shellcheck disable=SC2086,SC2317,SC2329  # intentional word-split on $RESTIC_BACKUP_OPTIONS; cron-invoked indirect functions
set -e

echo 'Do backup...'
MESSAGE="$(/usr/local/bin/restic ${RESTIC_BACKUP_OPTIONS} --host csb1 backup \
  --exclude '*/cache/*' --exclude '*.log*' \
  /backup/var/lib/docker/volumes /backup/var/lib/csb1-docker /backup/home /backup/root /backup/etc \
  2>&1 | tee /dev/tty)" || true

{
  echo To: $MAIL_TO
  echo From: $MAIL_FROM
  echo Subject: $MAIL_SUBJECT
  echo
  echo "Backup result:"
  echo
  echo "$MESSAGE"
} | ssmtp -v $MAIL_TO
