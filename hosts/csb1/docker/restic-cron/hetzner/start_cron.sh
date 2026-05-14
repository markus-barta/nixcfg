#!/bin/sh
# shellcheck disable=SC2086,SC2317,SC2329  # intentional word-split on $RESTIC_BACKUP_OPTIONS; cron-invoked indirect functions
set -e
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
