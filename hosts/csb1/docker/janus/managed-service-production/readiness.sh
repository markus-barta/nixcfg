#!/usr/bin/env bash
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "${script_dir}/../../../../.." && pwd)
compose="${repo}/hosts/csb1/docker/docker-compose.yml"
mode=${1:-declarative}
failures=0

pass() {
  printf 'ok: %s value_returned=false\n' "$1"
}

fail() {
  printf 'fail: %s value_returned=false\n' "$1" >&2
  failures=$((failures + 1))
}

check_command() {
  local id=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$id"
  else
    fail "$id"
  fi
}

service_image() {
  local service=$1
  awk -v service="$service" '
    $0 == "  " service ":" { inside = 1; next }
    inside && /^    image:/ { print $2; exit }
    inside && /^  [A-Za-z0-9_.-]+:/ { exit }
  ' "${compose}"
}

check_image_pin() {
  local id=$1
  local service=$2
  local pattern=$3
  local image
  image=$(service_image "$service")
  if [[ "$image" =~ $pattern ]]; then
    pass "$id"
  else
    fail "$id"
  fi
}

declarative() {
  check_command command_jq command -v jq
  check_command command_nix command -v nix
  check_command command_docker command -v docker
  check_command compose_contract docker compose -f "${compose}" config --quiet --no-interpolate
  check_command csb1_eval nix eval "${repo}#nixosConfigurations.csb1.config.system.build.toplevel.drvPath"
  check_command manifest_contract bash "${repo}/tests/T30-managed-service-manifest.sh"
  check_command host_envelope_contract bash "${repo}/tests/T31-janus-host-envelope.sh"

  check_image_pin \
    go_release_pin \
    janus \
    '^ghcr\.io/markus-barta/janus/janus-envelope:go-envelope-v1\.165@sha256:[0-9a-f]{64}$'
  check_image_pin \
    rust_release_pin \
    janus-managed-transactiond \
    '^ghcr\.io/markus-barta/janus/janus-engine:rust-engine-v0\.1\.11@sha256:[0-9a-f]{64}$'
  check_image_pin \
    pharos_release_pin \
    pharosd \
    '^ghcr\.io/markus-barta/pharos/pharosd:0\.1\.62@sha256:[0-9a-f]{64}$'

  if [ "$(service_image pharosd)" = "$(service_image pharos-beacon)" ]; then
    pass pharos_fleet_single_pin
  else
    fail pharos_fleet_single_pin
  fi

  check_command \
    admission_receipt \
    jq -e \
    '.schema_version == 1
     and .policy_id == "janus-engine-release-v1"
     and .channel == "stable"
     and .mode == "production"
     and .previous_mode == "production"
     and .artifact.tag == "rust-engine-v0.1.11"
     and (.artifact.digest | test("^sha256:[0-9a-f]{64}$"))
     and .artifact.development == false
     and .signature.verified == true
     and .provenance.verified == true
     and .sbom.verified == true' \
    "${script_dir}/release-admission.json"

  local activation
  activation=$(nix eval \
    "${repo}#nixosConfigurations.csb1.config.inspr.janusHostSecrets.enable" \
    --json 2>/dev/null || true)
  if [ "$activation" = "true" ] &&
    grep -Fq 'JANUS_PRODUCT_MODE=production' "${compose}" &&
    grep -Fq 'user: "100:993"' "${compose}" &&
    grep -Fq 'user: "65534:65534"' "${compose}" &&
    grep -Fq 'JANUS_MANAGED_WEB_TRANSACTION_ALLOWED_UID=100' "${compose}" &&
    grep -Fq 'network_mode: "none"' "${compose}" &&
    grep -Fq 'cap_drop: ["ALL"]' "${compose}" &&
    grep -Fq 'no-new-privileges:true' "${compose}"; then
    pass activation_and_hardening
  else
    fail activation_and_hardening
  fi

  if [ "$failures" -eq 0 ]; then
    printf 'managed_secret_readiness=ready mode=declarative value_returned=false\n'
  else
    printf 'managed_secret_readiness=blocked mode=declarative failures=%s value_returned=false\n' \
      "$failures" >&2
  fi
}

expect_metadata() {
  local id=$1
  local path=$2
  local expected_owner=$3
  local expected_mode=$4
  local actual_owner actual_mode
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fail "$id"
    return
  fi
  actual_owner=$(stat -c %u:%g "$path" 2>/dev/null || true)
  actual_mode=$(stat -c %a "$path" 2>/dev/null || true)
  if [ "$actual_owner" = "$expected_owner" ] && [ "$actual_mode" = "$expected_mode" ]; then
    pass "$id"
  else
    fail "$id"
  fi
}

expect_private_directory() {
  local id=$1
  local path=$2
  local actual_owner actual_mode
  actual_owner=$(stat -c %u:%g "$path" 2>/dev/null || true)
  actual_mode=$(stat -c %a "$path" 2>/dev/null || true)
  if [ -d "$path" ] && [ ! -L "$path" ] &&
    [ "$actual_owner" = "100:993" ] && [ "$actual_mode" = "700" ]; then
    pass "$id"
  else
    fail "$id"
  fi
}

expect_unit() {
  local unit=$1
  check_command "unit_${unit%.service}" systemctl is-active --quiet "$unit"
}

expect_container() {
  local name=$1
  local expected_user=$2
  local expected_network=$3
  local expected_readonly=$4
  local state
  state=$(docker inspect --format \
    '{{.State.Running}}|{{.Config.User}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}' \
    "$name" 2>/dev/null || true)
  if [[ "$state" == "true|${expected_user}|${expected_network}|${expected_readonly}|"* ]] &&
    [[ "$state" == *'["ALL"]'* ]] &&
    [[ "$state" == *'no-new-privileges:true'* ]]; then
    pass "container_${name}"
  else
    fail "container_${name}"
  fi
}

expect_healthy_container() {
  local name=$1
  local health
  health=$(docker inspect --format \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$name" 2>/dev/null || true)
  if [ "$health" = "healthy" ]; then
    pass "health_${name}"
  else
    fail "health_${name}"
  fi
}

live() {
  if [ "$(id -u)" != "0" ]; then
    fail live_requires_root
  fi
  if [ "$(hostname -s)" != "csb1" ]; then
    fail live_requires_csb1
  fi

  expect_metadata \
    internal_token_metadata \
    /run/agenix/csb1-janus-managed-internal-token \
    0:991 \
    440
  expect_metadata \
    pharos_signing_key_metadata \
    /run/agenix/csb1-janus-managed-pharos-signing-key \
    10001:992 \
    400
  expect_metadata \
    host_signing_key_metadata \
    /run/agenix/csb1-janus-managed-host-signing-key \
    100:993 \
    400
  expect_metadata \
    age_identity_metadata \
    /run/agenix/csb1-janus-managed-age-identity \
    100:993 \
    400
  expect_metadata \
    host_agent_token_metadata \
    /run/agenix/csb1-janus-managed-host-agent-token \
    0:0 \
    400

  local directory
  for directory in \
    /var/lib/janus-managed-central \
    /var/lib/janus-managed-central/age-store \
    /var/lib/janus-managed-central/audit \
    /var/lib/janus-managed-central/outbox \
    /var/lib/janus-managed-central/state \
    /var/lib/janus-managed-central/tombstones; do
    expect_private_directory "directory_$(basename "$directory")" "$directory"
  done
  expect_metadata \
    metadata_store \
    /var/lib/janus-managed-central/metadata.toml \
    100:993 \
    600

  expect_unit janus-managed-central-seed.service
  expect_unit janus-host-secret-restore.service
  expect_unit janus-managed-host-agent.service
  expect_unit janus-managed-canary.service

  expect_container janus-managed-transactiond 100:993 none true
  expect_container janus-managed-canary 65534:65534 none true
  expect_healthy_container janus
  expect_healthy_container pharosd
  expect_healthy_container janus-managed-canary

  local socket=/run/janus-managed-central/transaction.sock
  if [ -S "$socket" ] &&
    [ "$(stat -c %u:%g "$socket" 2>/dev/null)" = "100:993" ] &&
    [ "$(stat -c %a "$socket" 2>/dev/null)" = "600" ]; then
    pass transaction_socket
  else
    fail transaction_socket
  fi

  expect_metadata \
    release_audit \
    /var/lib/janus-managed-central/audit/release-admission.jsonl \
    100:993 \
    600
  expect_metadata \
    runtime_audit \
    /var/lib/janus-managed-central/audit/runtime.jsonl \
    100:993 \
    600

  if find /var/lib/janus-managed-central/state -maxdepth 2 \
    \( -name '*.tmp' -o -name '*.claim' \) -print -quit | grep -q .; then
    fail lifecycle_temporary_state
  else
    pass lifecycle_temporary_state
  fi

  local hash_root generation generation_file
  hash_root=$(docker volume inspect \
    --format '{{.Mountpoint}}' janus_pharos_production_hash_out 2>/dev/null || true)
  generation=
  if [ -n "$hash_root" ] && [ -f "${hash_root}/current" ]; then
    IFS= read -r generation <"${hash_root}/current"
  fi
  generation_file="${hash_root}/generation-${generation}.json"
  if [[ "$generation" =~ ^[0-9a-f]{64}$ ]] &&
    jq -e \
      '.schema == "inspr.pharos.beacon-token-generation.v2"
       and ([.hosts[] | select(.name == "host_58f36c72a91e")] | length) == 1' \
      "$generation_file" >/dev/null 2>&1; then
    pass host_agent_token_generation
  else
    fail host_agent_token_generation
  fi

  local service current expected
  for service in janus pharosd pharos-beacon janus-managed-transactiond; do
    current=$(docker inspect --format '{{.Config.Image}}' "$service" 2>/dev/null || true)
    expected=$(service_image "$service")
    if [ -n "$expected" ] && [ "$current" = "$expected" ]; then
      pass "image_${service}"
    else
      fail "image_${service}"
    fi
  done

  if [ "$failures" -eq 0 ]; then
    printf 'managed_secret_readiness=ready mode=live value_returned=false\n'
  else
    printf 'managed_secret_readiness=blocked mode=live failures=%s value_returned=false\n' \
      "$failures" >&2
  fi
}

case "$mode" in
declarative)
  declarative
  ;;
live)
  declarative
  if [ "$failures" -eq 0 ]; then
    live
  fi
  ;;
*)
  printf 'usage: %s declarative|live\n' "$0" >&2
  exit 2
  ;;
esac

if [ "$failures" -ne 0 ]; then
  exit 1
fi
