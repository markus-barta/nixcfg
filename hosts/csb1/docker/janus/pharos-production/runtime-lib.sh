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

  JANUS_PHAROS_CONTAINER_UID=$(docker run --rm --network none --entrypoint id "$image" -u)
  JANUS_PHAROS_CONTAINER_GID=$(docker run --rm --network none --entrypoint id "$image" -g)
  if [ "$JANUS_PHAROS_CONTAINER_UID" = 0 ]; then
    printf 'janus pharos runtime refused an image whose default user is root\n' >&2
    return 1
  fi

  docker run --rm --network none --user 0 \
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
find /run/janus/env/pharos/beacon-token-hashes -maxdepth 1 -type f -exec chmod 0600 {} +
' sh "$JANUS_PHAROS_CONTAINER_UID" "$JANUS_PHAROS_CONTAINER_GID"
}

# Provider rendering deliberately avoids re-owning the shared beacon output and
# permit volumes. Re-owning either during a provider refresh would break live
# beacon hash reads or interfere with an independent beacon permit run.
janus_pharos_prepare_provider_runtime() {
  local image=$1
  local contract_dir=$2
  local volume_prefix=$3
  local metadata_source="${contract_dir}/metadata.toml"

  [ -f "$metadata_source" ] || {
    printf 'janus pharos provider runtime metadata baseline is missing\n' >&2
    return 1
  }

  JANUS_PHAROS_AGE_VOLUME="${volume_prefix}_age"
  JANUS_PHAROS_STORE_VOLUME="${volume_prefix}_secrets"
  JANUS_PHAROS_METADATA_VOLUME="${volume_prefix}_metadata"

  local volume
  for volume in \
    "$JANUS_PHAROS_AGE_VOLUME" \
    "$JANUS_PHAROS_STORE_VOLUME" \
    "$JANUS_PHAROS_METADATA_VOLUME"; do
    docker volume create "$volume" >/dev/null
  done

  JANUS_PHAROS_CONTAINER_UID=$(docker run --rm --network none --entrypoint id "$image" -u)
  JANUS_PHAROS_CONTAINER_GID=$(docker run --rm --network none --entrypoint id "$image" -g)
  if [ "$JANUS_PHAROS_CONTAINER_UID" = 0 ]; then
    printf 'janus pharos provider runtime refused an image whose default user is root\n' >&2
    return 1
  fi

  docker run --rm --network none --user 0 \
    -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age" \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${metadata_source}:/bootstrap/metadata.toml:ro" \
    --entrypoint sh "$image" \
    -c '
set -eu
uid=$1
gid=$2
mkdir -p \
  /run/janus/age \
  /var/lib/janus/secrets/pharos \
  /var/lib/janus/metadata
if [ ! -e /var/lib/janus/metadata/metadata.toml ]; then
  install -o "$uid" -g "$gid" -m 0600 \
    /bootstrap/metadata.toml /var/lib/janus/metadata/metadata.toml
  install -o "$uid" -g "$gid" -m 0400 \
    /bootstrap/metadata.toml /var/lib/janus/metadata/baseline.toml
else
  test -f /var/lib/janus/metadata/baseline.toml || {
    printf "janus pharos provider runtime metadata baseline marker is missing\n" >&2
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
  /var/lib/janus/secrets \
  /var/lib/janus/metadata
chmod 0700 \
  /run/janus/age \
  /var/lib/janus/secrets \
  /var/lib/janus/secrets/pharos \
  /var/lib/janus/metadata
chmod 0600 /var/lib/janus/metadata/metadata.toml
chmod 0400 /var/lib/janus/metadata/baseline.toml
  ' sh "$JANUS_PHAROS_CONTAINER_UID" "$JANUS_PHAROS_CONTAINER_GID"
}

# Docker cannot create a nested volume target beneath a read-only parent mount.
# Prepare only the empty target directory that Compose needs; never inspect or
# mutate the sibling beacon output directories.
janus_pharos_prepare_provider_mountpoint() {
  local image=$1
  local shared_out_volume=$2

  docker volume create "$shared_out_volume" >/dev/null
  docker run --rm --network none --user 0 \
    -v "${shared_out_volume}:/run/janus/env" \
    --entrypoint sh "$image" \
    -c '
set -eu
parent=/run/janus/env/pharos
mountpoint=$parent/providers
test -d "$parent"
[ ! -L "$parent" ]
if [ -e "$mountpoint" ] || [ -L "$mountpoint" ]; then
  test -d "$mountpoint"
  [ ! -L "$mountpoint" ]
else
  mkdir "$mountpoint"
fi
first_entry=
if ! first_entry=$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit); then
  printf "failed to inspect the provider mountpoint\n" >&2
  exit 1
fi
[ -z "$first_entry" ]
chown 0:0 "$mountpoint"
chmod 0700 "$mountpoint"
'
}

janus_pharos_prepare_age_identity() {
  local image=$1
  local age_volume=$2
  local container_uid=$3
  local container_gid=$4

  if docker run --rm --network none \
    -v "${age_volume}:/run/janus/age" \
    --entrypoint sh "$image" \
    -c 'test -s /run/janus/age/identity && test -s /run/janus/age/recipient.pub'; then
    return 0
  fi

  command -v age-keygen >/dev/null 2>&1 || {
    printf 'missing required command: age-keygen\n' >&2
    return 1
  }

  (
    set -eu
    local key_dir
    key_dir=$(mktemp -d)
    trap 'rm -rf "$key_dir"' EXIT

    age-keygen -o "${key_dir}/identity" >"${key_dir}/age-keygen.out" 2>&1
    sed -n 's/^Public key: //p' "${key_dir}/age-keygen.out" | head -n1 >"${key_dir}/recipient.pub"
    sed -n 's/.*\(AGE-SECRET-KEY-[A-Z0-9]*\).*/\1/p' "${key_dir}/identity" |
      head -n1 >"${key_dir}/identity.plain"
    mv "${key_dir}/identity.plain" "${key_dir}/identity"
    if [ ! -s "${key_dir}/recipient.pub" ] || [ ! -s "${key_dir}/identity" ]; then
      printf 'failed to generate production age identity\n' >&2
      exit 1
    fi

    tar -C "$key_dir" -cf - identity recipient.pub |
      docker run -i --rm --network none --user 0 \
        -v "${age_volume}:/run/janus/age" \
        --entrypoint sh "$image" \
        -c '
set -eu
uid=$1
gid=$2
tmp=$(mktemp -d)
trap "rm -rf \"$tmp\"" EXIT
tar -C "$tmp" -xf -
install -o "$uid" -g "$gid" -m 0400 "$tmp/identity" /run/janus/age/identity
install -o "$uid" -g "$gid" -m 0444 "$tmp/recipient.pub" /run/janus/age/recipient.pub
' sh "$container_uid" "$container_gid"
  )
}
