#!/usr/bin/env bash
# NIX-600: the slot cache is a LUKS2 container file on the Lima data disk.
# At boot a job sees only ciphertext; the controller sends the key on stdin
# after it has attributed this runner's job to a verified run through the API.
#   cache-lock unlock <size-GiB> [--init]  (key on stdin) → mounted at /opt/aeon-cache
#     --init only for a disk the controller just created; a missing container on
#     an existing disk is an error, never silently replaced.
#   cache-lock lock                                 → unmounted and closed
set -euo pipefail

mnt=$(find /mnt -maxdepth 1 -name 'lima-aeon-*' -type d -print -quit)
[ -n "$mnt" ] || {
  echo "no slot disk attached" >&2
  exit 3
}
container="$mnt/cache.luks"

case "${1:-}" in
unlock)
  size="${2:?size in GiB}"
  init="${3:-}"
  install -d -m 0700 /run/aeon
  umask 077
  key=/run/aeon/cache.key
  trap 'rm -f "$key"' EXIT
  cat >"$key"
  fresh=""
  if [ ! -e "$container" ]; then
    [ "$init" = "--init" ] || {
      echo "cache container missing on an existing disk" >&2
      exit 4
    }
    truncate -s "${size}G" "$container"
    cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 \
      --pbkdf-force-iterations 1000 --key-file "$key" "$container"
    fresh=1
  fi
  cryptsetup open --type luks2 --key-file "$key" "$container" aeoncache
  rm -f "$key"
  if [ -n "$fresh" ]; then
    mkfs.ext4 -q -L aeon-cache /dev/mapper/aeoncache
  fi
  mount /dev/mapper/aeoncache /opt/aeon-cache
  chown runner:runner /opt/aeon-cache
  for d in go-build gomod npm ms-playwright toolcache; do
    install -d -o runner -g runner "/opt/aeon-cache/$d"
  done
  touch /var/lib/aeon/cache-ready
  ;;
lock)
  sync
  if mountpoint -q /opt/aeon-cache; then umount /opt/aeon-cache; fi
  if [ -e /dev/mapper/aeoncache ]; then cryptsetup close aeoncache; fi
  sync
  ;;
*)
  echo "usage: cache-lock unlock <GiB> | lock" >&2
  exit 2
  ;;
esac
