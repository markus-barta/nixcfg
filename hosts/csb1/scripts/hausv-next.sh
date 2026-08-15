#!/usr/bin/env bash
set -euo pipefail

readonly root=/var/lib/hausv-next
readonly data_dir="${root}/data"
readonly releases_dir="${root}/releases"
readonly quarantine_dir="${root}/quarantine"
readonly mirror="${root}/hausv-org.git"
readonly current_file="${root}/CURRENT"
readonly compose_file=/etc/hausv-next/compose.yml
readonly trusted_dockerfile=/etc/hausv-next/Dockerfile
readonly remote=https://github.com/inspr-at/hausv-org.git
readonly tailnet_ip=100.64.0.4
readonly port=8099

blocked() {
  printf 'BLOCKED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo hausv-next deploy <branch-or-commit>
  sudo hausv-next reset

The slot is available only at http://100.64.0.4:8099 over the tailnet.
Deploy accepts refs from the public inspr-at/hausv-org repository. Reset keeps
the previous fixture directory under /var/lib/hausv-next/quarantine and starts
the same commit with a fresh fixture directory.
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

validate_ref() {
  local ref=$1
  [ -n "${ref}" ] || blocked 'a branch or commit is required'
  [[ "${ref}" =~ ^[A-Za-z0-9][A-Za-z0-9._/@+-]*$ ]] ||
    blocked 'the ref contains unsupported characters'
  [[ "${ref}" != *..* && "${ref}" != *@\{* ]] ||
    blocked 'the ref contains unsafe revision syntax'
}

refresh_mirror() {
  if [ ! -e "${mirror}" ]; then
    local staging
    staging=$(mktemp -d "${root}/.mirror.XXXXXX")
    git clone --mirror "${remote}" "${staging}/repo.git"
    mv "${staging}/repo.git" "${mirror}"
    rmdir "${staging}"
  fi
  [ -d "${mirror}" ] && [ ! -L "${mirror}" ] ||
    blocked 'the HAUSV source mirror is not a real directory'
  [ "$(git -C "${mirror}" config --get remote.origin.url)" = "${remote}" ] ||
    blocked 'the HAUSV source mirror points at an unexpected remote'
  git -C "${mirror}" fetch --prune --tags origin \
    '+refs/heads/*:refs/remotes/origin/*'
}

resolve_commit() {
  local ref=$1
  local commit
  if commit=$(git -C "${mirror}" rev-parse --verify "${ref}^{commit}" 2>/dev/null); then
    :
  elif commit=$(git -C "${mirror}" rev-parse --verify "origin/${ref}^{commit}" 2>/dev/null); then
    :
  else
    blocked "${ref} is not a fetched hausv-org branch or commit"
  fi
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || blocked 'resolved commit is not a full SHA-1'
  printf '%s\n' "${commit}"
}

prepare_release() {
  local commit=$1
  local release="${releases_dir}/${commit}"
  if [ ! -e "${release}" ]; then
    local staging
    staging=$(mktemp -d "${root}/.release-${commit}.XXXXXX")
    git -C "${mirror}" archive "${commit}" | tar -x -C "${staging}"
    [ -f "${staging}/go.mod" ] || blocked 'selected commit has no go.mod'
    [ -f "${staging}/cmd/hausv-org/main.go" ] || blocked 'selected commit has no HAUSV main package'
    [ -f "${staging}/scripts/snapshot/fake-ha.mjs" ] ||
      blocked 'selected commit has no deterministic Home Assistant fixture'
    install -m 0444 "${trusted_dockerfile}" "${staging}/Dockerfile.preview"
    chmod 0755 "${staging}"
    mv "${staging}" "${release}"
  fi
  [ -d "${release}" ] && [ ! -L "${release}" ] ||
    blocked 'release context is not a real directory'
  printf '%s\n' "${release}"
}

compose() {
  local context=$1
  local commit=$2
  shift 2
  HAUSV_NEXT_CONTEXT="${context}" HAUSV_NEXT_COMMIT="${commit}" \
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
  local commit=$1
  local context=$2
  port_is_ours_or_free

  compose "${context}" "${commit}" pull fixture
  compose "${context}" "${commit}" build --pull app
  compose "${context}" "${commit}" up -d --remove-orphans --force-recreate app fixture

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
  printf '%s\n' "${commit}" >"${current_file}"
  chmod 0600 "${current_file}"
  printf 'HAUSV next deployed %s at http://%s:%s\n' "${commit}" "${tailnet_ip}" "${port}"
}

deploy_ref() {
  local ref=$1
  local commit context
  validate_ref "${ref}"
  refresh_mirror
  commit=$(resolve_commit "${ref}")
  context=$(prepare_release "${commit}")
  deploy_context "${commit}" "${context}"
}

reset_slot() {
  [ -f "${current_file}" ] && [ ! -L "${current_file}" ] ||
    blocked 'no deployed preview commit is recorded'
  local commit context timestamp previous_data
  commit=$(<"${current_file}")
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || blocked 'recorded preview commit is invalid'
  context="${releases_dir}/${commit}"
  [ -d "${context}" ] && [ ! -L "${context}" ] ||
    blocked 'recorded preview release is missing'

  compose "${context}" "${commit}" down --remove-orphans --volumes
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  previous_data="${quarantine_dir}/data-${timestamp}"
  [ ! -e "${previous_data}" ] || blocked 'reset quarantine target already exists'
  mv "${data_dir}" "${previous_data}"
  install -d -m 0750 -o 65532 -g 65532 "${data_dir}"
  deploy_context "${commit}" "${context}"
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
    [ "$#" -eq 2 ] || blocked 'deploy requires exactly one branch or commit'
    deploy_ref "$2"
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
