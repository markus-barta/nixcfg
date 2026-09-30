#!/usr/bin/env bash
# NIX-600: start the single-job JIT runner in a freshly cloned job VM.
# Runs as root via `limactl shell <vm> -- sudo /opt/aeon/start-runner`; the JIT
# config arrives on stdin and is only readable by root until the runner starts.
# The cache stays locked: /opt/aeon-cache is an empty directory until the
# controller has attributed this runner's job through the API (cache-lock).
set -euo pipefail

install -d -m 0700 /run/aeon
umask 077
cat >/run/aeon/jit
[ -s /run/aeon/jit ] || {
  echo "no JIT config on stdin" >&2
  exit 1
}

install -d -o runner -g runner /opt/aeon-cache
install -d -o runner -g runner -m 0755 /var/lib/aeon
rm -f /var/lib/aeon/admitted /var/lib/aeon/cache-ready
: >/var/lib/aeon/hook.log
chown runner:runner /var/lib/aeon/hook.log

systemctl start aeon-runner.service
