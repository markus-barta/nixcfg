#!/usr/bin/env bash
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "${script_dir}/../../../../.." && pwd)
if ! repo_revision=$(git -C "${repo}" rev-parse HEAD 2>/dev/null); then
  printf 'managed_secret_readiness=blocked reason=git_revision value_returned=false\n' >&2
  exit 1
fi
flake_ref="git+file://${repo}?rev=${repo_revision}&shallow=1"
# OPS-127: the compose spec is the source of truth (the yml is retired).
compose="${repo}/hosts/csb1/docker/compose-spec.nix"
# Compose cannot parse the nix spec; checks that shell out to docker compose
# read the closure's rendered JSON instead (identical content plus the
# module-injected dns keys), exactly like T32.
rendered_spec=""
mode=${1:-declarative}
failures=0

pass() {
  printf 'ok: %s value_returned=false\n' "$1"
}

fail() {
  printf 'fail: %s value_returned=false\n' "$1" >&2
  failures=$((failures + 1))
}

emit_terminal_verdict() {
  local requested_mode=$1
  local failure_count=$2
  if [ "$failure_count" -eq 0 ]; then
    printf 'managed_secret_readiness=ready mode=%s value_returned=false\n' \
      "$requested_mode"
  else
    printf 'managed_secret_readiness=blocked mode=%s failures=%s value_returned=false\n' \
      "$requested_mode" "$failure_count" >&2
  fi
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
    $0 == "    " service " = {" { inside = 1; next }
    inside && /^      image = "/ { gsub(/^      image = "|";$/, ""); print; exit }
    inside && $0 == "    };" { exit }
  ' "${compose}"
}

check_image_pin() {
  local id=$1
  local service=$2
  local pattern=$3
  local image
  local zero_digest
  image=$(service_image "$service")
  zero_digest="sha256:$(printf '0%.0s' {1..64})"
  if [[ "$image" =~ $pattern ]] && [[ "$image" != *"@${zero_digest}" ]]; then
    pass "$id"
  else
    fail "$id"
  fi
}

check_runtime_hardening() {
  local artifact_digest transaction_image
  artifact_digest=$(
    jq -er '.artifact.digest | select(test("^sha256:[0-9a-f]{64}$"))' \
      "${script_dir}/release-admission.json"
  ) || return 1
  transaction_image=$(service_image janus-managed-transactiond)

  docker compose \
    -f "${rendered_spec}" \
    config \
    --no-interpolate \
    --no-env-resolution \
    --no-path-resolution \
    --format json |
    jq -e \
      --arg artifact_digest "$artifact_digest" \
      --arg transaction_image "$transaction_image" \
      '
      def closed_bind($target; $read_only):
        any(.volumes[];
          .type == "bind"
          and .target == $target
          and ((.read_only // false) == $read_only)
          and .bind.create_host_path == false
        );
      .services["janus-managed-transactiond"] as $transaction
      | .services.janus as $janus
      | .services.pharosd as $pharos
      | .services["janus-managed-canary"] as $canary
      | $transaction.profiles == ["janus-managed-service"]
      and $transaction.restart == "no"
      and $transaction.init == true
      and $transaction.user == "100:993"
      and $transaction.read_only == true
      and $transaction.network_mode == "none"
      and $transaction.cap_drop == ["ALL"]
      and ($transaction.security_opt | index("no-new-privileges:true") != null)
      and $transaction.pids_limit == 64
      and $transaction.mem_limit == "128m"
      and $transaction.cpus == "0.50"
      and $transaction.healthcheck.test == ["CMD", "/usr/local/bin/janusd-use", "--help"]
      and $transaction.image == $transaction_image
      and ($transaction_image | endswith("@" + $artifact_digest))
      and ($transaction.environment | index("JANUS_PRODUCT_MODE=production") != null)
      and (
        $transaction.environment
        | index("JANUS_RELEASE_ARTIFACT_DIGEST=" + $artifact_digest) != null
      )
      and ($transaction.environment | index("JANUS_MANAGED_WEB_TRANSACTION_ALLOWED_UID=100") != null)
      and ($transaction | closed_bind("/var/lib/janus-managed-central"; false))
      and ($transaction | closed_bind("/run/janus-managed-central"; false))
      and ($transaction | closed_bind("/run/agenix/csb1-janus-managed-host-signing-key"; true))
      and ($transaction | closed_bind("/run/agenix/csb1-janus-managed-age-identity"; true))
      and ($transaction | closed_bind("/etc/janus/managed/release-channels-v1.json"; true))
      and ($transaction | closed_bind("/etc/janus/managed/release-admission.json"; true))
      and $janus.user == "100:101"
      and ($janus.group_add | index("991") != null)
      and any($janus.volumes[];
        .source == "/run/agenix/csb1-janus-managed-internal-token"
        and .target == "/run/janus/managed/internal-token"
        and .read_only == true
        and .bind.create_host_path == false
      )
      and ($janus | closed_bind("/run/janus-managed-central"; true))
      and ($janus | closed_bind("/var/lib/janus-managed-central/outbox"; true))
      and $pharos.user == "10001:992"
      and ($pharos.group_add | index("991") != null)
      and any($pharos.volumes[];
        .source == "/run/agenix/csb1-janus-managed-internal-token-pharos"
        and .target == "/run/pharos/managed-setup-internal-token"
        and .read_only == true
        and .bind.create_host_path == false
      )
      and ($pharos | closed_bind("/run/pharos/managed-setup-signing-key"; true))
      and ($pharos | closed_bind("/run/pharos/managed-setup-internal-token"; true))
      and $canary.init == true
      and $canary.user == "65534:65534"
      and $canary.read_only == true
      and $canary.network_mode == "none"
      and $canary.cap_drop == ["ALL"]
      and ($canary.security_opt | index("no-new-privileges:true") != null)
      and $canary.pids_limit == 32
      and $canary.mem_limit == "32m"
      and $canary.cpus == "0.10"
      and ($canary | closed_bind("/run/secrets/canary-api-token"; true))
    ' >/dev/null
}

check_reviewed_checkout() {
  if [[ "${repo}" =~ [[:space:]#?] ]] ||
    [[ ! "${repo_revision}" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  git -C "${repo}" diff --quiet --no-ext-diff -- &&
    git -C "${repo}" diff --cached --quiet --no-ext-diff -- &&
    ! git -C "${repo}" ls-files --others --exclude-standard | grep -q .
}

declarative() {
  check_command command_jq command -v jq
  check_command command_nix command -v nix
  check_command command_docker command -v docker
  check_command command_git command -v git
  check_command reviewed_checkout check_reviewed_checkout
  rendered_spec=$(mktemp)
  if nix eval --json \
    "${flake_ref}#nixosConfigurations.csb1.config.nixcfg.composeStack.renderedSpec" \
    >"${rendered_spec}" 2>/dev/null; then
    pass rendered_spec_eval
  else
    fail rendered_spec_eval
  fi
  check_command \
    compose_contract \
    docker compose -f "${rendered_spec}" config --quiet --no-interpolate --no-env-resolution --no-path-resolution
  check_command csb1_eval nix eval "${flake_ref}#nixosConfigurations.csb1.config.system.build.toplevel.drvPath"
  check_command manifest_contract "${BASH}" "${repo}/tests/T30-managed-service-manifest.sh"
  check_command host_envelope_contract "${BASH}" "${repo}/tests/T31-janus-host-envelope.sh"

  check_image_pin \
    go_release_pin \
    janus \
    '^ghcr\.io/inspr-at/janus/janus-envelope:go-envelope-v1\.181@sha256:[0-9a-f]{64}$'
  check_image_pin \
    rust_release_pin \
    janus-managed-transactiond \
    '^ghcr\.io/inspr-at/janus/janus-engine:rust-engine-v0\.1\.21@sha256:[0-9a-f]{64}$'
  check_image_pin \
    pharos_release_pin \
    pharosd \
    '^ghcr\.io/inspr-at/pharos/pharosd:0\.1\.81@sha256:[0-9a-f]{64}$'

  if [ "$(service_image pharosd)" = "$(service_image pharos-beacon)" ]; then
    pass pharos_fleet_single_pin
  else
    fail pharos_fleet_single_pin
  fi

  # $digest is a jq variable supplied by --arg, not a shell expansion.
  # shellcheck disable=SC2016
  check_command \
    rust_admission_receipt \
    jq -e --arg digest "$(service_image janus-managed-transactiond | sed 's/.*@//')" \
    '.schema_version == 1
     and .policy_id == "janus-engine-release-v1"
     and .policy_version == 3
     and .channel == "stable"
     and .mode == "production"
     and .previous_mode == "production"
     and .artifact.image == "ghcr.io/inspr-at/janus/janus-engine"
     and .artifact.tag == "rust-engine-v0.1.28"
     and .artifact.digest == $digest
     and .artifact.development == false
     and .signature.verified == true
     and .signature.identity == "https://github.com/inspr-at/janus/.github/workflows/rust.yml@refs/tags/rust-engine-v0.1.28"
     and .signature.oidc_issuer == "https://token.actions.githubusercontent.com"
     and .provenance.verified == true
     and .provenance.repository == "inspr-at/janus"
     and .provenance.signer_workflow == "inspr-at/janus/.github/workflows/rust.yml"
     and .provenance.source_ref == "refs/tags/rust-engine-v0.1.28"
     and .provenance.predicate_type == "https://slsa.dev/provenance/v1"
     and .sbom.verified == true
     and .sbom.predicate_type == "https://spdx.dev/Document/v2.3"
     and .source.verified == true
     and .source.commit == "217bd67eb9003497cd74282aeecc2f4bf4348916"
     and (.source.manifest_sha256 | test("^sha256:[0-9a-f]{64}$"))
     and (.source.bundle_sha256 | test("^sha256:[0-9a-f]{64}$"))
     and .scanner.verified == true
     and .scanner.name == "trivy"
     and .scanner.policy == "candidate_container_critical_high"
     and .scanner.subject == ("ghcr.io/inspr-at/janus/janus-engine@" + $digest)
     and (.scanner.summary_sha256 | test("^sha256:[0-9a-f]{64}$"))
     and .scanner.critical == 0
     and .scanner.high == 0' \
    "${script_dir}/release-admission.json"

  # shellcheck disable=SC2016
  check_command \
    go_admission_receipt \
    jq -e --arg digest "$(service_image janus | sed 's/.*@//')" \
    '.schema_version == 1
     and .policy_id == "janus-engine-release-v1"
     and .policy_version == 3
     and .channel == "envelope-stable"
     and .mode == "production"
     and .previous_mode == "production"
     and .artifact.image == "ghcr.io/inspr-at/janus/janus-envelope"
     and .artifact.tag == "go-envelope-v1.181"
     and .artifact.digest == $digest
     and .artifact.development == false
     and .signature.verified == true
     and .signature.identity == "https://github.com/inspr-at/janus/.github/workflows/go-envelope.yml@refs/tags/go-envelope-v1.181"
     and .signature.oidc_issuer == "https://token.actions.githubusercontent.com"
     and .provenance.verified == true
     and .provenance.repository == "inspr-at/janus"
     and .provenance.signer_workflow == "inspr-at/janus/.github/workflows/go-envelope.yml"
     and .provenance.source_ref == "refs/tags/go-envelope-v1.181"
     and .provenance.predicate_type == "https://slsa.dev/provenance/v1"
     and .sbom.verified == true
     and .sbom.predicate_type == "https://spdx.dev/Document/v2.3"
     and .source.verified == true
     and .source.commit == "44750404ed1f0673865791c3b54ded6d095bd8a1"
     and (.source.manifest_sha256 | test("^sha256:[0-9a-f]{64}$"))
     and (.source.bundle_sha256 | test("^sha256:[0-9a-f]{64}$"))
     and .scanner.verified == true
     and .scanner.name == "trivy"
     and .scanner.policy == "candidate_container_critical_high"
     and .scanner.subject == ("ghcr.io/inspr-at/janus/janus-envelope@" + $digest)
     and (.scanner.summary_sha256 | test("^sha256:[0-9a-f]{64}$"))
     and .scanner.critical == 0
     and .scanner.high == 0' \
    "${script_dir}/go-envelope-admission.json"

  local activation
  activation=$(nix eval \
    "${flake_ref}#nixosConfigurations.csb1.config.inspr.janusHostSecrets.enable" \
    --json 2>/dev/null || true)
  if [ "$activation" = "true" ]; then
    pass activation
  else
    fail activation
  fi
  check_command runtime_hardening check_runtime_hardening

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

expect_exact_container_image() {
  local name=$1
  local service=$2
  local actual expected
  actual=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true)
  expected=$(service_image "$service")
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    pass "image_${name}"
  else
    fail "image_${name}"
  fi
}

live() {
  if [ "$(id -u)" != "0" ]; then
    fail live_requires_root
  fi
  if [ "$(hostname -s)" != "csb1" ]; then
    fail live_requires_csb1
  fi
  if [ "$(git -C "${repo}" branch --show-current 2>/dev/null)" = "main" ]; then
    pass live_reviewed_main
  else
    fail live_reviewed_main
  fi

  expect_metadata \
    internal_token_janus_metadata \
    /run/agenix/csb1-janus-managed-internal-token \
    100:993 \
    400
  expect_metadata \
    internal_token_pharos_metadata \
    /run/agenix/csb1-janus-managed-internal-token-pharos \
    10001:992 \
    400
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
  expect_unit janus-managed-transactiond.service
  expect_unit janus-host-secret-restore.service
  expect_unit janus-managed-host-agent.service
  expect_unit janus-managed-canary.service

  expect_container janus-managed-transactiond 100:993 none true
  expect_container janus-managed-canary 65534:65534 none true
  expect_exact_container_image janus janus
  expect_exact_container_image pharosd pharosd
  expect_exact_container_image pharos-beacon pharos-beacon
  expect_exact_container_image janus-managed-transactiond janus-managed-transactiond
  expect_exact_container_image janus-managed-canary janus-managed-canary
  expect_healthy_container janus
  expect_healthy_container pharosd
  expect_healthy_container pharos-beacon
  expect_healthy_container janus-managed-transactiond
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
    /var/lib/janus-managed-central/audit/events.jsonl \
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
self-test)
  blocked_output=$(emit_terminal_verdict live 2 2>&1)
  ready_output=$(emit_terminal_verdict declarative 0 2>&1)
  if [ "$blocked_output" != "managed_secret_readiness=blocked mode=live failures=2 value_returned=false" ] ||
    [ "$ready_output" != "managed_secret_readiness=ready mode=declarative value_returned=false" ]; then
    printf 'managed_secret_readiness_self_test=failed value_returned=false\n' >&2
    exit 1
  fi
  printf 'managed_secret_readiness_self_test=passed value_returned=false\n'
  exit 0
  ;;
*)
  printf 'usage: %s declarative|live|self-test\n' "$0" >&2
  exit 2
  ;;
esac

emit_terminal_verdict "$mode" "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
