#!/usr/bin/env bash

janus_pharos_prepare_runtime() {
  local image=$1
  local contract_dir=$2
  local volume_prefix=$3
  local metadata_source="${contract_dir}/metadata.toml"

  [ -f "$metadata_source" ] || {
    printf 'janus pharos runtime metadata baseline is missing\n' >&2
    return 1
  }

  JANUS_PHAROS_AGE_VOLUME="${volume_prefix}_age"
  JANUS_PHAROS_STORE_VOLUME="${volume_prefix}_secrets"
  JANUS_PHAROS_PERMIT_VOLUME="${volume_prefix}_permits"
  JANUS_PHAROS_OUT_VOLUME="${volume_prefix}_out"
  JANUS_PHAROS_METADATA_VOLUME="${volume_prefix}_metadata"
  JANUS_PHAROS_LIFECYCLE_VOLUME="${volume_prefix}_lifecycle"

  local volume
  for volume in \
    "$JANUS_PHAROS_AGE_VOLUME" \
    "$JANUS_PHAROS_STORE_VOLUME" \
    "$JANUS_PHAROS_PERMIT_VOLUME" \
    "$JANUS_PHAROS_OUT_VOLUME" \
    "$JANUS_PHAROS_METADATA_VOLUME" \
    "$JANUS_PHAROS_LIFECYCLE_VOLUME"; do
    docker volume create "$volume" >/dev/null
  done

  JANUS_PHAROS_CONTAINER_UID=$(docker run --rm --entrypoint id "$image" -u)
  JANUS_PHAROS_CONTAINER_GID=$(docker run --rm --entrypoint id "$image" -g)
  if [ "$JANUS_PHAROS_CONTAINER_UID" = 0 ]; then
    printf 'janus pharos runtime refused an image whose default user is root\n' >&2
    return 1
  fi

  docker run --rm --user 0 \
    -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age" \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${JANUS_PHAROS_PERMIT_VOLUME}:/run/janus/permits" \
    -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
    -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${JANUS_PHAROS_LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle" \
    -v "${metadata_source}:/bootstrap/metadata.toml:ro" \
    --entrypoint sh "$image" \
    -c '
set -eu
uid=$1
gid=$2
mkdir -p \
  /run/janus/age \
  /run/janus/permits \
  /run/janus/env/pharos/beacons \
  /run/janus/env/pharos/beacon-token-hashes \
  /var/lib/janus/secrets/pharos \
  /var/lib/janus/metadata \
  /var/lib/janus/lifecycle/pharos-retirements \
  /var/lib/janus/lifecycle/tombstones
if [ ! -e /var/lib/janus/metadata/metadata.toml ]; then
  install -o "$uid" -g "$gid" -m 0600 \
    /bootstrap/metadata.toml /var/lib/janus/metadata/metadata.toml
  install -o "$uid" -g "$gid" -m 0400 \
    /bootstrap/metadata.toml /var/lib/janus/metadata/baseline.toml
else
  test -f /var/lib/janus/metadata/baseline.toml || {
    printf "janus pharos runtime metadata baseline marker is missing\n" >&2
    exit 1
  }
  source_digest=$(sha256sum /bootstrap/metadata.toml)
  source_digest=${source_digest%% *}
  retained_digest=$(sha256sum /var/lib/janus/metadata/baseline.toml)
  retained_digest=${retained_digest%% *}
  [ "$source_digest" = "$retained_digest" ] || {
    printf "janus pharos reviewed metadata baseline changed\n" >&2
    exit 1
  }
fi
test -f /var/lib/janus/metadata/metadata.toml
chown -R "$uid:$gid" \
  /run/janus/age \
  /run/janus/permits \
  /run/janus/env/pharos \
  /var/lib/janus/secrets \
  /var/lib/janus/metadata \
  /var/lib/janus/lifecycle
chmod 0700 \
  /run/janus/age \
  /run/janus/permits \
  /run/janus/env/pharos \
  /run/janus/env/pharos/beacons \
  /run/janus/env/pharos/beacon-token-hashes \
  /var/lib/janus/secrets \
  /var/lib/janus/secrets/pharos \
  /var/lib/janus/metadata \
  /var/lib/janus/lifecycle \
  /var/lib/janus/lifecycle/pharos-retirements \
  /var/lib/janus/lifecycle/tombstones
chmod 0600 /var/lib/janus/metadata/metadata.toml
chmod 0400 /var/lib/janus/metadata/baseline.toml
' sh "$JANUS_PHAROS_CONTAINER_UID" "$JANUS_PHAROS_CONTAINER_GID"
}
