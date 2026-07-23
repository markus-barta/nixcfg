#!/usr/bin/env bash

# The released Rust runtime is intentionally scratch-based: no shell, coreutils,
# package database, or named user exists in the image. Volume administration is
# isolated in this digest-pinned helper and never used to start Janus itself.
: "${JANUS_VOLUME_HELPER_IMAGE:=alpine:3.22.5@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce}"
readonly JANUS_VOLUME_HELPER_IMAGE
readonly JANUS_RUNTIME_UID=65532
readonly JANUS_RUNTIME_GID=65532

janus_assert_static_runtime_image() {
  local image=$1
  local configured_user
  local configured_entrypoint

  configured_user=$(docker image inspect --format '{{.Config.User}}' "$image")
  configured_entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
  if [ "$configured_user" != "${JANUS_RUNTIME_UID}:${JANUS_RUNTIME_GID}" ]; then
    printf 'Janus runtime must use exact uid/gid %s:%s (got %s)\n' \
      "$JANUS_RUNTIME_UID" "$JANUS_RUNTIME_GID" "$configured_user" >&2
    return 1
  fi
  if [ "$configured_entrypoint" != '["/usr/local/bin/janusd-use"]' ]; then
    printf 'Janus runtime has an unexpected entrypoint: %s\n' "$configured_entrypoint" >&2
    return 1
  fi
}
