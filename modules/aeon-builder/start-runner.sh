#!/usr/bin/env bash
# NIX-600: start the single-job JIT runner in a freshly cloned job VM.
# Runs as root via `limactl shell <vm> -- sudo /opt/aeon/start-runner`; the JIT
# config arrives on stdin and is only readable by root until the runner starts.
set -euo pipefail

install -d -m 0700 /run/aeon
umask 077
cat >/run/aeon/jit
[ -s /run/aeon/jit ] || {
  echo "no JIT config on stdin" >&2
  exit 1
}

# The slot's disk (trusted cache for main pushes, a disposable copy otherwise).
disk=$(find /mnt -maxdepth 1 -name "lima-aeon-*" -type d -print -quit)
install -d -o runner -g runner /opt/aeon-cache
if [ -n "$disk" ]; then
  mount --bind "$disk" /opt/aeon-cache
  chown runner:runner /opt/aeon-cache
fi
for d in go-build gomod npm ms-playwright toolcache; do
  install -d -o runner -g runner "/opt/aeon-cache/$d"
done

install -d -o runner -g runner -m 0755 /var/lib/aeon
: >/var/lib/aeon/hook.log
chown runner:runner /var/lib/aeon/hook.log

systemctl start aeon-runner.service
