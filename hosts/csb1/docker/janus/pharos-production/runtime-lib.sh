#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/runtime-image-policy.sh"

janus_pharos_load_consumer_identity() {
  local compose_dir=$1
  local compose_file="${compose_dir}/docker-compose.yml"
  local configured_user

  if ! configured_user=$(
    docker compose \
      --project-directory "$compose_dir" \
      -f "$compose_file" \
      config \
      --no-env-resolution \
      --no-path-resolution \
      --format json |
      jq -er '.services.pharosd.user | select(type == "string" and length > 0)'
  ); then
    printf 'pharosd must declare an explicit numeric runtime user\n' >&2
    return 1
  fi
  if [[ ! "$configured_user" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]; then
    printf 'pharosd runtime user must be an explicit non-root uid:gid\n' >&2
    return 1
  fi

  # Globals are the library return contract consumed by each renderer.
  # shellcheck disable=SC2034
  JANUS_PHAROS_CONSUMER_UID=${configured_user%%:*}
  # shellcheck disable=SC2034
  JANUS_PHAROS_CONSUMER_GID=${configured_user#*:}
}

janus_pharos_publish_hash_projection() {
  local source_volume=$1
  local projection_volume=$2
  local consumer_uid=$3
  local consumer_gid=$4

  [ "$source_volume" != "$projection_volume" ] || {
    printf 'janus pharos hash projection must use a dedicated volume\n' >&2
    return 1
  }
  [[ "$consumer_uid" =~ ^[1-9][0-9]*$ ]] || {
    printf 'janus pharos hash projection consumer uid is invalid\n' >&2
    return 1
  }
  [[ "$consumer_gid" =~ ^[1-9][0-9]*$ ]] || {
    printf 'janus pharos hash projection consumer gid is invalid\n' >&2
    return 1
  }
  docker volume inspect "$source_volume" >/dev/null 2>&1 || {
    printf 'janus pharos private source volume is unavailable\n' >&2
    return 1
  }

  docker volume create "$projection_volume" >/dev/null
  docker run --rm --network none --user 0 \
    -v "${source_volume}:/source:ro" \
    -v "${projection_volume}:/projection" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
uid=$1
gid=$2
source_root=/source/pharos/beacon-token-hashes
projection_root=/projection

test -d "$source_root"
[ ! -L "$source_root" ]
test -f "$source_root/current"
[ ! -L "$source_root/current" ]
IFS= read -r generation <"$source_root/current"
printf "%s" "$generation" | grep -Eq "^[0-9a-f]{64}$"
source_generation="$source_root/generation-${generation}.json"
test -s "$source_generation"
[ ! -L "$source_generation" ]

test -d "$projection_root"
[ ! -L "$projection_root" ]
find "$projection_root" -mindepth 1 -maxdepth 1 -type f \
  -name ".janus-pharos-publish-*.tmp" -delete
valid_projection_name() {
  name=$1
  [ "$name" = current ] && return 0
  case "$name" in
  generation-*.json)
    id=${name#generation-}
    id=${id%.json}
    printf "%s" "$id" | grep -Eq "^[0-9a-f]{64}$"
    ;;
  *) return 1 ;;
  esac
}
for entry in "$projection_root"/* "$projection_root"/.[!.]* "$projection_root"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=${entry##*/}
  if ! valid_projection_name "$name"; then
    printf "janus pharos hash projection contains an unexpected entry\n" >&2
    exit 1
  fi
  test -f "$entry"
  [ ! -L "$entry" ]
done

generation_target="$projection_root/generation-${generation}.json"
generation_tmp="$projection_root/.janus-pharos-publish-generation.$$.tmp"
current_tmp="$projection_root/.janus-pharos-publish-current.$$.tmp"
cleanup() {
  rm -f "$generation_tmp" "$current_tmp"
}
trap cleanup EXIT HUP INT TERM

cp "$source_generation" "$generation_tmp"
chown "$uid:$gid" "$generation_tmp"
chmod 0640 "$generation_tmp"
if [ -e "$generation_target" ]; then
  test -f "$generation_target"
  [ ! -L "$generation_target" ]
  cmp -s "$generation_tmp" "$generation_target"
  rm -f "$generation_tmp"
else
  mv "$generation_tmp" "$generation_target"
fi

printf "%s\n" "$generation" >"$current_tmp"
chown "$uid:$gid" "$current_tmp"
chmod 0640 "$current_tmp"
sync
mv "$current_tmp" "$projection_root/current"
chown "$uid:$gid" "$projection_root"
chmod 0750 "$projection_root"
find "$projection_root" -maxdepth 1 -type f -name "generation-*.json" \
  -exec chown "$uid:$gid" {} + \
  -exec chmod 0640 {} +
sync
' sh "$consumer_uid" "$consumer_gid"

  docker run --rm --network none --user "${consumer_uid}:${consumer_gid}" \
    -v "${projection_volume}:/run/pharos/beacon-token-hashes:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
uid=$1
gid=$2
root=/run/pharos/beacon-token-hashes
test -d "$root"
[ ! -L "$root" ]
[ "$(stat -c "%u:%g:%a" "$root")" = "${uid}:${gid}:750" ]
test -r "$root/current"
[ ! -L "$root/current" ]
[ "$(stat -c "%u:%g:%a" "$root/current")" = "${uid}:${gid}:640" ]
IFS= read -r generation <"$root/current"
printf "%s" "$generation" | grep -Eq "^[0-9a-f]{64}$"
generation_file="$root/generation-${generation}.json"
test -s "$generation_file"
test -r "$generation_file"
[ ! -L "$generation_file" ]
[ "$(stat -c "%u:%g:%a" "$generation_file")" = "${uid}:${gid}:640" ]
cat "$generation_file" >/dev/null
valid_projection_name() {
  name=$1
  [ "$name" = current ] && return 0
  case "$name" in
  generation-*.json)
    id=${name#generation-}
    id=${id%.json}
    printf "%s" "$id" | grep -Eq "^[0-9a-f]{64}$"
    ;;
  *) return 1 ;;
  esac
}
for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=${entry##*/}
  valid_projection_name "$name"
  test -f "$entry"
  [ ! -L "$entry" ]
  [ "$(stat -c "%u:%g:%a" "$entry")" = "${uid}:${gid}:640" ]
  test -r "$entry"
done
' sh "$consumer_uid" "$consumer_gid"
}

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
  JANUS_PHAROS_HASH_OUT_VOLUME=${JANUS_PHAROS_HASH_OUT_VOLUME:-"${volume_prefix}_hash_out"}
  JANUS_PHAROS_METADATA_VOLUME="${volume_prefix}_metadata"
  JANUS_PHAROS_LIFECYCLE_VOLUME="${volume_prefix}_lifecycle"

  local volume
  for volume in \
    "$JANUS_PHAROS_AGE_VOLUME" \
    "$JANUS_PHAROS_STORE_VOLUME" \
    "$JANUS_PHAROS_PERMIT_VOLUME" \
    "$JANUS_PHAROS_OUT_VOLUME" \
    "$JANUS_PHAROS_HASH_OUT_VOLUME" \
    "$JANUS_PHAROS_METADATA_VOLUME" \
    "$JANUS_PHAROS_LIFECYCLE_VOLUME"; do
    docker volume create "$volume" >/dev/null
  done

  janus_assert_static_runtime_image "$image"
  JANUS_PHAROS_CONTAINER_UID=$JANUS_RUNTIME_UID
  JANUS_PHAROS_CONTAINER_GID=$JANUS_RUNTIME_GID

  docker run --rm --network none --user 0 \
    -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age" \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${JANUS_PHAROS_PERMIT_VOLUME}:/run/janus/permits" \
    -v "${JANUS_PHAROS_OUT_VOLUME}:/run/janus/env" \
    -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${JANUS_PHAROS_LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle" \
    -v "${metadata_source}:/bootstrap/metadata.toml:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
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

  janus_assert_static_runtime_image "$image"
  JANUS_PHAROS_CONTAINER_UID=$JANUS_RUNTIME_UID
  JANUS_PHAROS_CONTAINER_GID=$JANUS_RUNTIME_GID

  docker run --rm --network none --user 0 \
    -v "${JANUS_PHAROS_AGE_VOLUME}:/run/janus/age" \
    -v "${JANUS_PHAROS_STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${JANUS_PHAROS_METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${metadata_source}:/bootstrap/metadata.toml:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
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

janus_pharos_prepare_age_identity() {
  local image=$1
  local age_volume=$2
  local container_uid=$3
  local container_gid=$4

  if docker run --rm --network none \
    -v "${age_volume}:/run/janus/age" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
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
        --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
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
