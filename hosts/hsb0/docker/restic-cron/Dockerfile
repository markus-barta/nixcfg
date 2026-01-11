FROM alpine:latest

ENV RESTIC_VERSION="0.15.2"

# Cleanup params
ENV RESTIC_CLEANUP_KEEP_DAILY=7
ENV RESTIC_CLEANUP_KEEP_WEEKLY=5
ENV RESTIC_CLEANUP_KEEP_MONTHLY=12
ENV RESTIC_CLEANUP_KEEP_YEARLY=3
ENV RESTIC_CLEANUP_OPTIONS="--prune"

ENV MAIL_TO="markus@barta.com"
ENV MAIL_FROM="markus@barta.com"
ENV MAIL_SUBJECT="💾 Restic backup report"
ENV RESTIC_PASSWORD=""
ENV RESTIC_BACKUP_OPTIONS=""

# Default interval times can be set in cron expression
# Fire at 00:30 every day
ENV CRON_BACKUP_EXPRESSION="30   0  *   *   *"
# Fire at 03:15 every day
ENV CRON_CLEANUP_EXPRESSION="15  3  *   *   *"
# Fire at 05:30 every month
ENV CRON_CHECK_EXPRESSION="30  5  1   *   *"

RUN apk add --no-cache ca-certificates fuse bzip2 gnupg openssh-client supervisor ssmtp curl && \
    mkdir -p /var/log/supervisor

RUN curl -L https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2 | \
    bzip2 -d > /usr/local/bin/restic && \
    chmod a+x /usr/local/bin/restic

# Script and config
ADD ./hetzner/start_cron.sh /usr/local/bin
ADD ./hetzner/run_backup.sh /usr/local/bin
ADD ./hetzner/run_check.sh /usr/local/bin
ADD ./hetzner/run_cleanup.sh /usr/local/bin
ADD ./hetzner/supervisor_restic.ini /etc/supervisor.d/restic.ini
ADD ./hetzner/ssmtp.conf /etc/ssmtp/ssmtp.conf
RUN chmod +x /usr/local/bin/*.sh

# Start the process
CMD supervisord -c /etc/supervisord.conf
