#!/usr/bin/env bash
# NIX-600: the slot cache is a LUKS2 container file on the Lima data disk.
# At boot a job sees only ciphertext; the controller sends the key on stdin
# after it has attributed this runner's job to a verified run through the API.
#   cache-lock unlock <size-GiB>   (key on stdin)  → mounted at /opt/aeon-cache
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
  install -d -m 0700 /run/aeon
  umask 077
  key=/run/aeon/cache.key
  cat >"$key"
  fresh=""
  if [ ! -e "$container" ]; then
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
