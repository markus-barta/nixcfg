#!/usr/bin/env bash
# NIX-393 + HOSTD-14: the four remaining boards consume exact host truth.
# This gate is deliberately browser-free: it evaluates the real NixOS configs,
# parses the pinned HostDash config files, and drives the production jq filter
# with synthetic running/stopped/noise records.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old; run under bash 5\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flake_ref=${NIX393_FLAKE_REF:-$repo_root}
filter="$repo_root/modules/files/hostdash-container-status.jq"
module="$repo_root/modules/hostdash-status.nix"
collector="$repo_root/modules/files/hostdash-container-status.sh"
pin=136988907cdbba4fa56ebfa6a4dd8cf8ff5f845e

fail() {
  printf 'hostdash_status_fleet=failed reason=%s\n' "$1" >&2
  exit 1
}

for command in nix jq node; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command"
done

# Container discovery is authoritative input. A Docker or jq failure must abort
# the producer transaction, not be converted into a fresh empty object that makes
# every bound card look merely absent. Drive the exact production collector with
# deterministic command stubs and the producer's temp-file/atomic-swap pattern.
if grep -Fq "|| echo '{}')" "$module"; then
  fail container_collection_failure_publishes_empty_truth
fi
[[ -f "$collector" ]] || fail container_collector_missing
grep -Fq 'hostdash-container-status' "$module" || fail container_collector_not_consumed
# Literal generated-shell source pattern.
# shellcheck disable=SC2016
collector_invocation=$(sed -n '/containers="$(hostdash-container-status/,/)"/p' "$module")
[[ -n "$collector_invocation" ]] || fail container_collector_invocation_missing
if grep -Eq '\|\||(^|[[:space:]])(echo|true)([[:space:]]|$)' <<<"$collector_invocation"; then
  fail container_collector_invocation_fails_open
fi
# Literal generated-shell source pattern.
# shellcheck disable=SC2016
grep -Fq 'trap '\''rm -f "$TMP"'\'' EXIT' "$module" || fail producer_temp_cleanup_missing
# Literal generated-shell source pattern.
# shellcheck disable=SC2016
grep -Fq 'mv -f "$TMP" "$OUT"' "$module" || fail producer_atomic_swap_missing
# Path is the fixed repository helper above.
# shellcheck source=/dev/null
source "$collector"
export -f hostdash_collect_containers

producer_fixture=$(mktemp -d)
cleanup_producer_fixture() {
  find "$producer_fixture" -type f -delete
  find "$producer_fixture" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup_producer_fixture EXIT
fixture_out="$producer_fixture/status.json"
printf '{"sentinel":true}\n' >"$fixture_out"

run_producer_fixture() {
  local docker_status=$1 jq_status=$2
  DOCKER_TEST_STATUS="$docker_status" \
    JQ_TEST_STATUS="$jq_status" \
    REAL_JQ="$(command -v jq)" \
    bash -c '
      set -euo pipefail
      filter=$1
      out=$2
      docker() {
        printf "%s\n" "{\"Names\":\"allowed\",\"State\":\"running\",\"Status\":\"Up 1 minute (healthy)\"}"
        return "$DOCKER_TEST_STATUS"
      }
      jq() {
        if [[ "$JQ_TEST_STATUS" != 0 ]]; then return "$JQ_TEST_STATUS"; fi
        "$REAL_JQ" "$@"
      }
      export -f docker jq
      tmp=$(mktemp "${out%/*}/.status.XXXXXX")
      trap '\''rm -f "$tmp"'\'' EXIT
      containers=$(hostdash_collect_containers '\''["allowed","missing"]'\'' "$filter")
      "$REAL_JQ" -n --argjson containers "$containers" '\''{containers:$containers}'\'' >"$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$out"
      trap - EXIT
    ' bash "$filter" "$fixture_out"
}

if run_producer_fixture 74 0 >/dev/null 2>&1; then
  fail docker_failure_accepted
fi
jq -e '.sentinel == true' "$fixture_out" >/dev/null || fail docker_failure_replaced_last_good_artifact
if find "$producer_fixture" -name '.status.*' -print -quit | grep -q .; then
  fail docker_failure_left_partial_artifact
fi

if run_producer_fixture 0 75 >/dev/null 2>&1; then
  fail jq_failure_accepted
fi
jq -e '.sentinel == true' "$fixture_out" >/dev/null || fail jq_failure_replaced_last_good_artifact
if find "$producer_fixture" -name '.status.*' -print -quit | grep -q .; then
  fail jq_failure_left_partial_artifact
fi

run_producer_fixture 0 0
jq -e '
  .containers.allowed.running == true
  and (.containers | has("missing") | not)
' "$fixture_out" >/dev/null || fail successful_collection_or_missing_allowlist_contract

locked=$(jq -r '.nodes.hostdash.locked.rev' "$repo_root/flake.lock")
[[ "$locked" == "$pin" ]] || fail hostdash_pin_drift
[[ "$(jq -r '.nodes.hostdash.original.repo' "$repo_root/flake.lock")" == hostdash ]] ||
  fail hostdash_original_repo_drift

hostdash_source=$(nix eval --impure --raw --expr \
  "(builtins.getFlake \"path:${flake_ref}\").inputs.hostdash.outPath")
bindings='{}'
for host in csb0 csb1 hsb8 hsb9; do
  config="$hostdash_source/hosts/$host/config.js"
  [[ -f "$config" ]] || fail "${host}_config_missing"
  host_facts=$(node "$repo_root/tests/hostdash-status-bindings.mjs" <"$config") ||
    fail "${host}_config_not_static"
  host_bindings=$(jq -ce \
    '.bindings |= (map({key: .name, value: del(.name)}) | from_entries)' \
    <<<"$host_facts") || fail "${host}_binding_normalization_failed"
  bindings=$(jq -cn \
    --argjson current "$bindings" \
    --arg host "$host" \
    --argjson hostBindings "$host_bindings" \
    '$current + {($host): $hostBindings}')
done

# A prototype-looking service name remains inert data in the entries output.
prototype_facts=$(printf '%s\n' \
  'window.HOSTDASH_CONFIG = {' \
  '  services: [{ name: "__proto__", container: "safe" }],' \
  '};' | node "$repo_root/tests/hostdash-status-bindings.mjs") ||
  fail prototype_name_rejected
jq -e '. == {bindings:[{name:"__proto__",container:"safe"}],unbound:[]}' \
  <<<"$prototype_facts" >/dev/null || fail prototype_name_not_inert

# Executable/computed values and duplicate keys fail closed; the extractor
# never evaluates JavaScript or assigns a source-derived property to an object.
if printf '%s\n' \
  'window.HOSTDASH_CONFIG = {' \
  '  services: [{ name: "dynamic", container: lookupContainer() }],' \
  '};' | node "$repo_root/tests/hostdash-status-bindings.mjs" >/dev/null 2>&1; then
  fail dynamic_hostdash_config_accepted
fi
if printf '%s\n' \
  'window.HOSTDASH_CONFIG = {' \
  '  services: [{ name: "first", name: "second", container: "safe" }],' \
  '};' | node "$repo_root/tests/hostdash-status-bindings.mjs" >/dev/null 2>&1; then
  fail duplicate_hostdash_key_accepted
fi

[[ "$(jq '[.[] .bindings | length] | add' <<<"$bindings")" == 45 ]] ||
  fail binding_count_drift

eval_json() {
  nix eval --no-update-lock-file --json \
    "${flake_ref}#nixosConfigurations.$1.config.$2"
}

has_systemd_object() {
  local host=$1 kind=$2 name=$3
  nix eval --no-update-lock-file --json \
    --apply "objects: builtins.hasAttr \"$name\" objects" \
    "${flake_ref}#nixosConfigurations.${host}.config.systemd.${kind}" | jq -e '. == true' >/dev/null
}

for host in csb0 csb1 hsb8 hsb9; do
  status=$(eval_json "$host" services.hostdash.status)
  [[ "$(jq -r '.enable' <<<"$status")" == true ]] || fail "${host}_status_disabled"
  [[ "$(jq -r '.host' <<<"$status")" == "$host" ]] || fail "${host}_stamp_drift"

  declared_containers=$(jq -c '.containers | sort' <<<"$status")
  card_containers=$(jq -c --arg host "$host" \
    '[.[$host].bindings[] | .container? // empty] | sort' <<<"$bindings")
  [[ "$declared_containers" == "$card_containers" ]] || fail "${host}_container_parity"

  declared_units=$(jq -c '.units | sort' <<<"$status")
  card_units=$(jq -c --arg host "$host" \
    '[.[$host].bindings[] | .unit? // empty] | sort' <<<"$bindings")
  [[ "$declared_units" == "$card_units" ]] || fail "${host}_unit_parity"

  declared_extras=$(jq -c '.mqttExtras | keys | sort' <<<"$status")
  card_extras=$(jq -c --arg host "$host" \
    '[.[$host].bindings[] | .extra? // empty] | sort' <<<"$bindings")
  [[ "$declared_extras" == "$card_extras" ]] || fail "${host}_extra_parity"

  if [[ "$host" == csb0 ]]; then
    [[ "$(jq -c --arg host "$host" '.[$host].unbound' <<<"$bindings")" == '["SMTP relay"]' ]] ||
      fail csb0_absent_smtp_not_explicit
  else
    [[ "$(jq -c --arg host "$host" '.[$host].unbound' <<<"$bindings")" == '[]' ]] ||
      fail "${host}_unbound_card"
  fi

  # HTTP evidence is optional, but every configured key must be one of the
  # exact card bindings; a separately named probe can never reach the card.
  if ! jq -e '
    ((.containers // []) + (.units // []) + (.mqttExtras | keys)) as $runtime
    | [.httpProbes | keys[] | . as $key | $runtime | index($key) != null] | all
  ' <<<"$status" >/dev/null; then
    fail "${host}_http_key_not_bound"
  fi

  spec=$(eval_json "$host" nixcfg.composeStack.spec)
  project=$(nix eval --no-update-lock-file --raw \
    "${flake_ref}#nixosConfigurations.${host}.config.nixcfg.composeStack.project")
  runtime_names=$(jq -c --arg project "$project" '
    [.services | to_entries[] | (.value.container_name // ($project + "-" + .key + "-1"))]
  ' <<<"$spec")
  while IFS= read -r container; do
    if jq -e --arg name "$container" 'index($name) != null' <<<"$runtime_names" >/dev/null; then
      continue
    fi
    if [[ "$host" == csb1 && "$container" == hausv-org ]] &&
      grep -Fq 'hausvCompose = ' "$repo_root/hosts/csb1/configuration.nix" &&
      grep -Fq "docker inspect --format '{{.State.Running}}' hausv-org" \
        "$repo_root/hosts/csb1/configuration.nix"; then
      continue
    fi
    fail "${host}_container_not_declared_${container}"
  done < <(jq -r '.containers[]' <<<"$status")

  while IFS= read -r unit; do
    name=${unit%.*}
    case "$unit" in
    *.timer) has_systemd_object "$host" timers "$name" || fail "${host}_timer_missing_${name}" ;;
    *.service) has_systemd_object "$host" services "$name" || fail "${host}_service_missing_${name}" ;;
    *) fail "${host}_unsupported_unit_${unit}" ;;
    esac
  done < <(jq -r '.units[]' <<<"$status")

  dashboard=$([[ "$host" == csb0 || "$host" == csb1 ]] && printf hostdash || printf '%s-home' "$host")
  volumes=$(jq -c --arg service "$dashboard" '.services[$service].volumes' <<<"$spec")
  jq -e 'index("/var/lib/hostdash-status:/srv/hostdash-status:ro") != null' <<<"$volumes" >/dev/null ||
    fail "${host}_status_mount_missing"
  jq -e 'index("/etc/hostdash-nginx.conf:/etc/nginx/conf.d/default.conf:ro") != null' <<<"$volumes" >/dev/null ||
    fail "${host}_nginx_mount_missing"
done

# hsb8 is manifest mode: the generated document, the Pharos copy, and the
# pinned HostDash fallback must all carry the same binding map.
hsb8_manifest=$(eval_json hsb8 services.hostdash.manifest.generated)
hsb8_manifest_bindings=$(jq -c '
  [.services[] | {
    key: .name,
    value: ({container, unit, extra} | with_entries(select(.value != null)))
  }] | from_entries
' <<<"$hsb8_manifest")
hsb8_source_bindings=$(jq -c '.hsb8.bindings' <<<"$bindings")
[[ "$hsb8_manifest_bindings" == "$hsb8_source_bindings" ]] || fail hsb8_manifest_binding_drift
diff -u \
  <(jq -S . <<<"$hsb8_manifest") \
  <(jq -S . "$repo_root/hosts/csb1/docker/pharos/manifests/hsb8.json") >/dev/null ||
  fail hsb8_pharos_manifest_drift

# Drive the real production filter. The allowlist must retain honest running,
# stopped, unhealthy, and starting states while dropping unrelated containers.
container_fixture=$(printf '%s\n' \
  '{"Names":"running","State":"running","Status":"Up 3 minutes (healthy)"}' \
  '{"Names":"stopped","State":"exited","Status":"Exited (1) 2 minutes ago"}' \
  '{"Names":"unhealthy","State":"running","Status":"Up 1 minute (unhealthy)"}' \
  '{"Names":"starting","State":"running","Status":"Up 4 seconds (health: starting)"}' \
  '{"Names":"noise","State":"running","Status":"Up 9 hours (healthy)"}' |
  jq -s --argjson allowed '["running","stopped","unhealthy","starting"]' -f "$filter")
jq -e '
  (keys | sort) == ["running", "starting", "stopped", "unhealthy"]
  and .running == {running:true,state:"running",status:"Up 3 minutes (healthy)",health:"healthy"}
  and .stopped.running == false and .stopped.health == null
  and .unhealthy.running == true and .unhealthy.health == "unhealthy"
  and .starting.running == true and .starting.health == "starting"
' <<<"$container_fixture" >/dev/null || fail container_state_filter

# Null remains the compatibility mode for hsb0/hsb1; explicit [] means no
# container keys, never an accidental enumerate-all.
[[ "$(printf '%s\n' '{"Names":"legacy","State":"running","Status":"Up"}' |
  jq -cs --argjson allowed null -f "$filter" | jq -c 'keys')" == '["legacy"]' ]] ||
  fail legacy_filter_changed
[[ "$(printf '%s\n' '{"Names":"noise","State":"running","Status":"Up"}' |
  jq -cs --argjson allowed '[]' -f "$filter" | jq -c 'keys')" == '[]' ]] ||
  fail empty_allowlist_enumerates_noise

options_result=$(nix eval --impure --json --expr "
  let flake = builtins.getFlake \"path:${flake_ref}\"; in
  import ${repo_root}/tests/hostdash-status-options-eval.nix {
    nixpkgs = flake.inputs.nixpkgs;
    system = \"x86_64-linux\";
  }
")
jq -e '[.positive[], .negative[]] | all' <<<"$options_result" >/dev/null ||
  fail option_negative_fixture

# Staleness is enforced by the exact pinned consumer, not inferred from browser
# reachability. The one-minute producer cadence stays well inside the five-minute
# discard boundary, and the client returns null once that boundary is crossed.
client="$hostdash_source/public/index.html"
grep -Fq 'const STATUS_MAX_AGE_MS = 5 * 60 * 1000;' "$client" || fail stale_budget_drift
grep -Fq 'if (ageSec * 1000 > STATUS_MAX_AGE_MS)' "$client" || fail stale_guard_missing
grep -Fq 'TRUTH = { state: "stale"' "$client" || fail stale_truth_missing
grep -A4 -F 'if (ageSec * 1000 > STATUS_MAX_AGE_MS)' "$client" | grep -Fq 'return null;' ||
  fail stale_artifact_not_discarded

[[ "$(grep -Fc 'tests/T59-hostdash-status-fleet.sh' "$repo_root/.github/workflows/check.yml")" == 1 ]] ||
  fail ci_wiring_count

printf 'hostdash_status_fleet=ok hosts=4 bindings=%s pin=%s\n' \
  "$(jq '[.[] .bindings | length] | add' <<<"$bindings")" "$pin"
