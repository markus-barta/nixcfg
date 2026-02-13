#!/bin/sh
set -e

check() {
  echo
  echo "Check ${REPOSITORY}..."
  echo

  MESSAGE="$(/usr/local/bin/restic check "${RESTIC_BACKUP_OPTIONS}" --read-data 2>&1)" || true

  {
    echo To: "$MAIL_TO"
    echo From: "$MAIL_FROM"
    echo Subject: "☑️ Restic Check ${REPOSITORY} (hetzner)"
    echo
    echo "Check result:"
    echo
    echo "$MESSAGE"
  } | ssmtp "$MAIL_TO"
}

# check repository
export REPOSITORY=hsb0
check
