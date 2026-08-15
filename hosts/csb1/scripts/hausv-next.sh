#!/usr/bin/env bash
set -euo pipefail

readonly root=/var/lib/hausv-next
readonly data_dir="${root}/data"
readonly releases_dir="${root}/releases"
readonly quarantine_dir="${root}/quarantine"
readonly current_file="${root}/CURRENT"
readonly compose_file=/etc/hausv-next/compose.yml
readonly trusted_dockerfile=/etc/hausv-next/Dockerfile
readonly tailnet_ip=100.64.0.4
readonly port=8099

blocked() {
  printf 'BLOCKED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  git archive --format=tar <ref> | ssh csb1 sudo hausv-next deploy <label>
  sudo hausv-next reset

The slot is available only at http://100.64.0.4:8099 over the tailnet.
Deploy reads a HAUSV source tar archive from stdin. The label is informational
only and is never fetched. Reset keeps the previous fixture directory under
/var/lib/hausv-next/quarantine and starts the same release with a fresh fixture
directory.
EOF
}

require_preconditions() {
  [ "$(id -u)" -eq 0 ] || blocked 'run this command with sudo'
  [ -r "${compose_file}" ] || blocked 'the NixOS configuration is not activated'
  [ -r "${trusted_dockerfile}" ] || blocked 'the trusted preview Dockerfile is missing'
  ip -4 address show dev tailscale0 2>/dev/null |
    grep -Fq "${tailnet_ip}/" ||
    blocked "tailscale0 does not own ${tailnet_ip}"
  install -d -m 0700 "${root}" "${releases_dir}" "${quarantine_dir}"
  if [ -L "${data_dir}" ]; then
    blocked "${data_dir} must never be a symlink"
  fi
  install -d -m 0750 -o 65532 -g 65532 "${data_dir}"
  [ "$(readlink -f "${data_dir}")" = "${data_dir}" ] ||
    blocked 'preview data path did not resolve exactly'
}

validate_label() {
  local label=$1
  [ -n "${label}" ] || blocked 'a display label is required'
  [ "${#label}" -le 128 ] || blocked 'the display label is longer than 128 characters'
  [[ "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$ ]] ||
    blocked 'the display label contains unsupported characters'
}

validate_archive() {
  local archive=$1
  [ -s "${archive}" ] || blocked 'stdin did not contain a tar archive'

  # Reject absolute paths and parent traversal before extraction. Only regular
  # files and directories are accepted, which also prevents link-based escape.
  tar --list --file "${archive}" --quoting-style=literal |
    awk '
      function unsafe(path, count, parts, i) {
        if (path == "" || substr(path, 1, 1) == "/") return 1
        count = split(path, parts, "/")
        for (i = 1; i <= count; i++) if (parts[i] == "..") return 1
        return 0
      }
      unsafe($0) { bad = 1 }
      END { exit bad }
    ' || blocked 'the archive contains an unsafe path'

  tar --list --verbose --file "${archive}" |
    awk '
      substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { bad = 1 }
      END { exit bad }
    ' || blocked 'the archive contains a link or special file'
}

prepare_release() {
  local staging archive context archive_hash staging_suffix release_id release
  staging=$(mktemp -d "${root}/.release.XXXXXX")
  archive="${staging}/source.tar"
  context="${staging}/context"
  cat >"${archive}"
  validate_archive "${archive}"
  install -d -m 0755 "${context}"
  tar --extract --file "${archive}" --directory "${context}" \
    --no-same-owner --no-same-permissions --delay-directory-restore

  [ -f "${context}/go.mod" ] || blocked 'the archive has no go.mod'
  [ -f "${context}/cmd/hausv-org/main.go" ] || blocked 'the archive has no HAUSV main package'
  [ -f "${context}/scripts/snapshot/fake-ha.mjs" ] ||
    blocked 'the archive has no deterministic Home Assistant fixture'
  install -m 0444 "${trusted_dockerfile}" "${context}/Dockerfile.preview"

  archive_hash=$(sha256sum "${archive}" | awk '{print $1}')
  [[ "${archive_hash}" =~ ^[0-9a-f]{64}$ ]] || blocked 'could not identify the archive'
  staging_suffix=${staging##*.release.}
  [[ "${staging_suffix}" =~ ^[A-Za-z0-9]+$ ]] || blocked 'invalid staging directory suffix'
  release_id="${archive_hash}-${staging_suffix}"
  release="${releases_dir}/${release_id}"
  [ ! -e "${release}" ] || blocked 'release target already exists'
  mv "${staging}" "${release}"
  context="${release}/context"
  [ -d "${context}" ] && [ ! -L "${context}" ] ||
    blocked 'release context is not a real directory'
  printf '%s\t%s\n' "${release_id}" "${context}"
}

compose() {
  local context=$1
  local release_id=$2
  local label=$3
  shift 3
  HAUSV_NEXT_CONTEXT="${context}" HAUSV_NEXT_RELEASE_ID="${release_id}" \
    HAUSV_NEXT_LABEL="${label}" \
    docker compose --project-name hausv-next --file "${compose_file}" "$@"
}

port_is_ours_or_free() {
  if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
    docker ps \
      --filter label=com.docker.compose.project=hausv-next \
      --filter label=com.docker.compose.service=app \
      --format '{{.Names}}' |
      grep -Fxq hausv-next ||
      blocked "tailnet port ${port} is already owned by another process"
  fi
}

deploy_context() {
  local release_id=$1
  local label=$2
  local context=$3
  port_is_ours_or_free

  compose "${context}" "${release_id}" "${label}" pull fixture
  compose "${context}" "${release_id}" "${label}" build --pull app
  compose "${context}" "${release_id}" "${label}" up -d --remove-orphans --force-recreate app fixture

  local ready=0
  for _ in $(seq 1 24); do
    if curl --fail --silent --show-error \
      "http://${tailnet_ip}:${port}/healthz" >/dev/null; then
      ready=1
      break
    fi
    sleep 5
  done
  [ "${ready}" -eq 1 ] || blocked 'the preview did not become healthy'
  printf '%s\t%s\n' "${release_id}" "${label}" >"${current_file}"
  chmod 0600 "${current_file}"
  printf 'HAUSV next deployed %s at http://%s:%s\n' "${label}" "${tailnet_ip}" "${port}"
}

deploy_archive() {
  local label=$1
  local release_id context prepared
  validate_label "${label}"
  [ ! -t 0 ] || blocked 'deploy requires a tar archive on stdin'
  prepared=$(prepare_release)
  IFS=$'\t' read -r release_id context <<<"${prepared}"
  deploy_context "${release_id}" "${label}" "${context}"
}

reset_slot() {
  [ -f "${current_file}" ] && [ ! -L "${current_file}" ] ||
    blocked 'no deployed preview release is recorded'
  local release_id label context timestamp previous_data
  IFS=$'\t' read -r release_id label <"${current_file}"
  [[ "${release_id}" =~ ^[0-9a-f]{64}-[A-Za-z0-9]+$ ]] ||
    blocked 'recorded preview release is invalid'
  validate_label "${label}"
  context="${releases_dir}/${release_id}/context"
  [ -d "${context}" ] && [ ! -L "${context}" ] ||
    blocked 'recorded preview release is missing'

  compose "${context}" "${release_id}" "${label}" down --remove-orphans --volumes
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  previous_data="${quarantine_dir}/data-${timestamp}"
  [ ! -e "${previous_data}" ] || blocked 'reset quarantine target already exists'
  mv "${data_dir}" "${previous_data}"
  install -d -m 0750 -o 65532 -g 65532 "${data_dir}"
  deploy_context "${release_id}" "${label}" "${context}"
}

main() {
  [ "$#" -ge 1 ] || {
    usage
    exit 2
  }
  case "$1" in
  -h | --help | help)
    usage
    exit 0
    ;;
  esac
  require_preconditions
  exec 9>/run/lock/compose-hausv-next.lock
  flock -w 300 9 || blocked 'another HAUSV preview operation still holds the lock'
  case "$1" in
  deploy)
    [ "$#" -eq 2 ] || blocked 'deploy requires exactly one display label'
    deploy_archive "$2"
    ;;
  reset)
    [ "$#" -eq 1 ] || blocked 'reset takes no arguments'
    reset_slot
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
}

main "$@"
