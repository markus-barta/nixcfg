#!/bin/sh
# shellcheck disable=SC2086,SC2317,SC2329  # intentional word-split on $RESTIC_BACKUP_OPTIONS; cron-invoked indirect functions
set -e

# Checkup is done on csb0 (cs0.barta.cm) so exit 0 here
exit 0

check() {
  echo
  echo "Check ${REPOSITORY}..."
  echo

  MESSAGE="$(/usr/local/bin/restic check ${RESTIC_BACKUP_OPTIONS} --read-data 2>&1 | tee /dev/tty)" || true

  {
    echo To: $MAIL_TO
    echo From: $MAIL_FROM
    echo Subject: ☑️ Restic Check ${REPOSITORY} \(hetzner\)
    echo
    echo "Check result:"
    echo
    echo "$MESSAGE"
  } | ssmtp $MAIL_TO
}

# check repository
export REPOSITORY=csb0
check
