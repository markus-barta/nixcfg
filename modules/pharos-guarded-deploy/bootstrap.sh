#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR='/var/lib/pharos-guarded-deploy'
readonly STORE_DIR='/var/lib/janus/secrets/pharos-deploy/@HOST@'
readonly IDENTITY='/etc/ssh/ssh_host_ed25519_key'
readonly RECIPIENTS='/etc/ssh/ssh_host_ed25519_key.pub'

mkdir -p "$STATE_DIR" "$STATE_DIR/approvals" "$STATE_DIR/evidence" "$STATE_DIR/permits" \
  "$STATE_DIR/requests" "$STATE_DIR/results" "$STATE_DIR/runs" "$STORE_DIR"
chmod 0700 "$STATE_DIR" "$STATE_DIR/approvals" "$STATE_DIR/evidence" "$STATE_DIR/permits" \
  "$STATE_DIR/requests" "$STATE_DIR/results" "$STATE_DIR/runs" \
  /var/lib/janus /var/lib/janus/secrets /var/lib/janus/secrets/pharos-deploy "$STORE_DIR"

for name in @APPLY_SECRET_NAME@ @ROLLBACK_SECRET_NAME@ @UPDATE_SECRET_NAME@; do
  target="$STORE_DIR/$name.age"
  if [ ! -s "$target" ]; then
    tmp=$(mktemp "$STATE_DIR/.capability.XXXXXX")
    trap 'test ! -e "$tmp" || { shred -u "$tmp" 2>/dev/null || true; }' EXIT
    openssl rand -base64 48 | age -R "$RECIPIENTS" -o "$tmp"
    age --decrypt -i "$IDENTITY" "$tmp" >/dev/null
    install -o root -g root -m 0400 "$tmp" "$target"
    shred -u "$tmp" 2>/dev/null || true
    trap - EXIT
  fi
  age --decrypt -i "$IDENTITY" "$target" >/dev/null
done

printf 'pharos_guarded_deploy_bootstrap=ready value_returned=false\n'
