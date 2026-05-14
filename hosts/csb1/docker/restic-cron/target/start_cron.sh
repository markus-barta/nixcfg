#!/bin/sh
# shellcheck disable=SC2086,SC2317,SC2329  # intentional word-split on $RESTIC_BACKUP_OPTIONS; cron-invoked indirect functions
set -e
echo "${CRON_BACKUP_EXPRESSION} supervisorctl start restic_backup" | crontab -
/usr/sbin/crond -f
