#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos agenix import failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

JANUS_HOST=${JANUS_PHAROS_JANUS_HOST:-csb1}
REMOTE_REPO=${JANUS_PHAROS_REMOTE_REPO:-/home/mba/Code/nixcfg}
VOLUME_PREFIX=${JANUS_PHAROS_VOLUME_PREFIX:-janus_pharos_production}
HOSTS_TEXT=${JANUS_PHAROS_HOSTS:-"csb0 csb1 dsc0 gpc0 hsb0 hsb1 hsb8 hsb9"}
ALLOW_MISSING_TEXT=${JANUS_PHAROS_ALLOW_MISSING_HOSTS:-}
SSH_OPTS=${JANUS_PHAROS_SSH_OPTS:-"-o BatchMode=yes -o ConnectTimeout=8"}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RETIREMENTS_FILE=${JANUS_PHAROS_RETIREMENTS_FILE:-${SCRIPT_DIR}/retired-hosts.json}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../runtime-image-policy.sh"

read -r -a HOSTS <<<"$HOSTS_TEXT"
ALLOW_MISSING=()
if [ -n "$ALLOW_MISSING_TEXT" ]; then
  read -r -a ALLOW_MISSING <<<"$ALLOW_MISSING_TEXT"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

validate_identifier() {
  name=$1
  value=$2
  case "$value" in
  "" | *[!A-Za-z0-9_.-]*)
    printf 'invalid %s: %s\n' "$name" "$value" >&2
    exit 1
    ;;
  esac
}

is_allowed_missing() {
  local needle=$1
  local item
  if [ "${#ALLOW_MISSING[@]}" -eq 0 ]; then
    return 1
  fi
  for item in "${ALLOW_MISSING[@]}"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

bash_quote() {
  printf '%q' "$1"
}

run_remote_script() {
  local host=$1
  local script=$2
  local encoded
  encoded=$(printf '%s' "$script" | base64 | tr -d '\n')
  # The encoded script is assembled locally from reviewed constants.
  # shellcheck disable=SC2029
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$host" "printf '%s' '$encoded' | base64 -d | bash"
}

remote_csb1() {
  local script=$1
  run_remote_script "$JANUS_HOST" "$script"
}

require_command age
require_command base64
require_command jq
require_command scp
require_command ssh
require_command tr

validate_identifier JANUS_PHAROS_JANUS_HOST "$JANUS_HOST"
validate_identifier JANUS_PHAROS_VOLUME_PREFIX "$VOLUME_PREFIX"
for host in "${HOSTS[@]}"; do
  validate_identifier host "$host"
done

jq -e '
  ((keys | sort) == ["retirements", "schema", "version"])
  and .schema == "inspr.pharos.janus-retirements.v1"
  and .version == 1
  and (.retirements | type == "array")
  and all(.retirements[];
    ((keys | sort) == [
      "credential_retirement_required",
      "disposition",
      "host",
      "server_deletion",
      "successor"
    ])
    and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.disposition == "destroyed" or .disposition == "unmanaged" or .disposition == "rebuilt")
    and (.successor == null or (.successor | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")))
    and .credential_retirement_required == true
    and .server_deletion == false
  )
' "$RETIREMENTS_FILE" >/dev/null || {
  printf 'invalid Pharos retirement intent\n' >&2
  exit 1
}

ACTIVE_HOSTS=()
for host in "${HOSTS[@]}"; do
  if jq -e --arg host "$host" '.retirements[] | select(.host == $host)' \
    "$RETIREMENTS_FILE" >/dev/null; then
    continue
  fi
  ACTIVE_HOSTS+=("$host")
done
HOSTS=("${ACTIVE_HOSTS[@]}")
if [ "${#ALLOW_MISSING[@]}" -gt 0 ]; then
  for host in "${ALLOW_MISSING[@]}"; do
    validate_identifier allow_missing_host "$host"
  done
fi

AGE_VOLUME="${VOLUME_PREFIX}_age"
STORE_VOLUME="${VOLUME_PREFIX}_secrets"
TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

remote_csb1 "cd '$REMOTE_REPO' && JANUS_PHAROS_VOLUME_PREFIX='$VOLUME_PREFIX' JANUS_PHAROS_PREPARE_ONLY=1 bash hosts/csb1/docker/janus/pharos-production/render-sidecars.sh" >/dev/null

IMAGE=$(
  remote_csb1 "cd '$REMOTE_REPO/hosts/csb1/docker' && awk '
    /^[[:space:]]+janus-engine-staged:/ { in_service = 1; next }
    in_service && /^    image:/ { print \$2; exit }
    in_service && /^  [A-Za-z0-9_-]+:/ { exit }
  ' docker-compose.yml"
)
if [ -z "$IMAGE" ]; then
  printf 'could not resolve Janus engine image on %s\n' "$JANUS_HOST" >&2
  exit 1
fi

container_uid=$JANUS_RUNTIME_UID
container_gid=$JANUS_RUNTIME_GID

recipient=$(
  remote_csb1 "docker run --rm -v '${AGE_VOLUME}:/run/janus/age:ro' --entrypoint cat '$JANUS_VOLUME_HELPER_IMAGE' /run/janus/age/recipient.pub" |
    tr -d '\r\n'
)
if [ -z "$recipient" ]; then
  printf 'production Janus recipient is empty\n' >&2
  exit 1
fi

fetch_token() {
  local host=$1
  local env_file="/run/agenix/pharos-beacon-${host}-env"
  local remote_script
  case "$host" in
  dsc0)
    env_file="${JANUS_PHAROS_DSC0_ENV_FILE:-/run/agenix/dsc0-pharos-beacon-env}"
    ;;
  esac
  remote_script=$(
    cat <<EOF
set -euo pipefail
set -a
source "$env_file"
set +a
test -n "\${PHAROS_TOKEN:-}"
printf '%s' "\$PHAROS_TOKEN"
EOF
  )
  run_remote_script "$host" "$remote_script"
}

store_encrypted() {
  local host=$1
  local secret_name=$2
  local encrypted_file=$3
  local remote_tmp
  local docker_script
  local remote_script
  remote_tmp="/tmp/janus-pharos-${host}-$(date +%s%N).age"
  docker_script=$(
    cat <<'EOF'
set -eu
host=$1
secret_name=$2
uid=$3
gid=$4
dir="/var/lib/janus/secrets/pharos/${host}"
tmp="${dir}/.${secret_name}.age.tmp"
mkdir -p "$dir"
chown "${uid}:${gid}" "$dir"
chmod 0700 "$dir"
cat /tmp/input.age >"$tmp"
chown "${uid}:${gid}" "$tmp"
chmod 0400 "$tmp"
mv "$tmp" "${dir}/${secret_name}.age"
EOF
  )

  # shellcheck disable=SC2086
  scp $SSH_OPTS "$encrypted_file" "${JANUS_HOST}:${remote_tmp}" >/dev/null
  remote_script=$(
    cat <<EOF
set -euo pipefail
trap 'rm -f $(bash_quote "$remote_tmp")' EXIT
docker run --rm --user 0 \\
  -v $(bash_quote "${STORE_VOLUME}:/var/lib/janus/secrets") \\
  -v $(bash_quote "${remote_tmp}:/tmp/input.age:ro") \\
  --entrypoint sh $(bash_quote "$JANUS_VOLUME_HELPER_IMAGE") \\
  -c $(bash_quote "$docker_script") \\
  sh $(bash_quote "$host") $(bash_quote "$secret_name") $(bash_quote "$container_uid") $(bash_quote "$container_gid")
EOF
  )
  run_remote_script "$JANUS_HOST" "$remote_script"
}

imported=()
missing=()
for host in "${HOSTS[@]}"; do
  upper=$(printf '%s' "$host" | tr '[:lower:]' '[:upper:]')
  secret_name="PHAROS_BEACON_${upper}_TOKEN"
  encrypted_file="${TMP_DIR}/${host}.age"

  if fetch_token "$host" | age -r "$recipient" -o "$encrypted_file"; then
    store_encrypted "$host" "$secret_name" "$encrypted_file"
    imported+=("$host")
    printf 'ok: imported existing beacon token for %s into Janus value_returned=false\n' "$host"
  else
    if is_allowed_missing "$host"; then
      missing+=("$host")
      printf 'warning: skipped missing allowed host %s value_returned=false\n' "$host" >&2
      continue
    fi
    printf 'failed to import existing beacon token for %s\n' "$host" >&2
    exit 1
  fi
done

if [ "${#imported[@]}" -eq 0 ]; then
  printf 'no hosts imported\n' >&2
  exit 1
fi

render_hosts="${imported[*]}"
remote_csb1 "cd '$REMOTE_REPO' && JANUS_PHAROS_VOLUME_PREFIX='$VOLUME_PREFIX' JANUS_PHAROS_HOSTS='$render_hosts' bash hosts/csb1/docker/janus/pharos-production/render-sidecars.sh"

if [ "${#missing[@]}" -gt 0 ]; then
  printf 'warning: janus pharos agenix import incomplete missing_hosts=%s value_returned=false\n' "${missing[*]}" >&2
fi

printf 'ok: janus pharos agenix import completed imported_hosts=%s value_returned=false\n' "$render_hosts"
