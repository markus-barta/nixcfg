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
# every bound card look merely absent. Resolve the exact evaluated generator and
# collector derivations, then drive the shipped collector wrapper with deterministic
# command functions. Nothing here touches Docker or /var/lib.
if grep -Fq "|| echo '{}')" "$module"; then
  fail container_collection_failure_publishes_empty_truth
fi
[[ -f "$collector" ]] || fail container_collector_missing

generator_attr="${flake_ref}#nixosConfigurations.csb0.config.systemd.services.hostdash-status.serviceConfig.ExecStart"
generator_exec=$(nix eval --raw "$generator_attr") || fail generator_exec_eval_failed
generator_context=$(nix eval --json --apply 'value: builtins.getContext value' "$generator_attr") ||
  fail generator_context_eval_failed
generator_drv=$(jq -er 'keys | if length == 1 then .[0] else error("ambiguous generator context") end' \
  <<<"$generator_context") || fail generator_drv_not_unique

# The legacy `nix show-derivation DRV` interface returns either its longstanding
# top-level absolute drv key and inputDrvs fields or the current version-4 envelope
# with basename drv keys and inputs.drvs fields. Treat these as two coupled schemas:
# unknown versions, mixed internals, non-canonical store names, extras, and multiple
# derivations fail closed.
normalize_derivation_json() {
  jq -ce '
    def canonical_store_name:
      type == "string"
      and test("^[0123456789abcdfghijklmnpqrsvwxyz]{32}-[-+._?=A-Za-z0-9]+$");
    def canonical_drv_basename:
      canonical_store_name and endswith(".drv");
    def canonical_absolute_store_path:
      type == "string"
      and startswith("/nix/store/")
      and (.[11:] | canonical_store_name);
    def canonical_absolute_drv_path:
      canonical_absolute_store_path and endswith(".drv");
    def exact_entry($object):
      ($object | to_entries) as $entries
      | if (($entries | length) == 1)
        then $entries[0]
        else error("derivation set must contain exactly one entry")
        end;
    def exact_output($drv; $variant):
      if (($drv.outputs? | type) != "object"
          or ($drv.outputs | keys) != ["out"]
          or ($drv.outputs.out | type) != "object"
          or ($drv.outputs.out | keys) != ["path"]
          or ($drv.outputs.out.path | type) != "string") then
        error("derivation output schema is malformed")
      elif $variant == "current" and ($drv.outputs.out.path | canonical_store_name) then
        "/nix/store/" + $drv.outputs.out.path
      elif $variant == "legacy" and ($drv.outputs.out.path | canonical_absolute_store_path) then
        $drv.outputs.out.path
      else
        error("derivation output path does not match its schema")
      end;
    if (type == "object" and keys == ["derivations", "version"]
        and .version == 4 and (.derivations | type) == "object") then
      exact_entry(.derivations) as $entry
      | $entry.value as $drv
      | if (($entry.key | canonical_drv_basename)
            and ($drv | type) == "object"
            and ($drv.inputs? | type) == "object"
            and ($drv.inputs.drvs? | type) == "object"
            and (($drv.inputs.drvs | length) > 0)
            and (all($drv.inputs.drvs | keys[]; canonical_drv_basename))
            and ($drv | has("inputDrvs") | not)) then
          {
            variant: "current",
            key: $entry.key,
            drv_path: ("/nix/store/" + $entry.key),
            value: $drv,
            input_drv_paths: [$drv.inputs.drvs | keys[] | "/nix/store/" + .],
            output_path: exact_output($drv; "current")
          }
        else
          error("current derivation schema is malformed")
        end
    elif (type == "object" and (keys | length) == 1) then
      exact_entry(.) as $entry
      | $entry.value as $drv
      | if (($entry.key | canonical_absolute_drv_path)
            and ($drv | type) == "object"
            and ($drv.inputDrvs? | type) == "object"
            and (($drv.inputDrvs | length) > 0)
            and (all($drv.inputDrvs | keys[]; canonical_absolute_drv_path))
            and ($drv | has("inputs") | not)) then
          {
            variant: "legacy",
            key: $entry.key,
            drv_path: $entry.key,
            value: $drv,
            input_drv_paths: [$drv.inputDrvs | keys[]],
            output_path: exact_output($drv; "legacy")
          }
        else
          error("legacy derivation schema is malformed")
        end
    elif (type == "object" and keys == ["derivations", "version"]) then
      error("unsupported versioned derivation schema")
    else
      error("unknown or ambiguous derivation schema")
    end
  '
}

derivation_input_drv_paths() {
  jq -ce '
    if (.input_drv_paths | type) == "array" and (.input_drv_paths | length) > 0 then
      .input_drv_paths
    else
      error("normalized derivation inputs are missing")
    end
  '
}

fixture_current_drv=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fixture.drv
fixture_current_output=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-fixture-out
fixture_current_dependency=cccccccccccccccccccccccccccccccc-dependency.drv
fixture_legacy_drv=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fixture.drv
fixture_legacy_output=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-fixture-out
fixture_legacy_dependency=/nix/store/cccccccccccccccccccccccccccccccc-dependency.drv
fixture_body_current=$(jq -cn \
  --arg output "$fixture_current_output" \
  --arg dependency "$fixture_current_dependency" \
  '{env:{text:"fixture"},outputs:{out:{path:$output}},inputs:{drvs:{($dependency):{outputs:["out"]}}}}')
fixture_body_legacy=$(jq -cn \
  --arg output "$fixture_legacy_output" \
  --arg dependency "$fixture_legacy_dependency" \
  '{env:{text:"fixture"},outputs:{out:{path:$output}},inputDrvs:{($dependency):["out"]}}')
wrapped_fixture=$(jq -cn --argjson body "$fixture_body_current" \
  --arg drv "$fixture_current_drv" '{version:4,derivations:{($drv):$body}}')
top_level_fixture=$(jq -cn --argjson body "$fixture_body_legacy" \
  --arg drv "$fixture_legacy_drv" '{($drv):$body}')
wrapped_fixture_entry=$(normalize_derivation_json <<<"$wrapped_fixture") ||
  fail wrapped_derivation_fixture_rejected
top_level_fixture_entry=$(normalize_derivation_json <<<"$top_level_fixture") ||
  fail top_level_derivation_fixture_rejected
jq -e --arg drv "$fixture_current_drv" \
  --arg output "$fixture_legacy_output" \
  '.variant == "current" and .key == $drv and .value.env.text == "fixture" and .output_path == $output' \
  <<<"$wrapped_fixture_entry" >/dev/null || fail wrapped_derivation_fixture_changed
jq -e --arg drv "$fixture_legacy_drv" \
  --arg output "$fixture_legacy_output" \
  '.variant == "legacy" and .key == $drv and .value.env.text == "fixture" and .output_path == $output' \
  <<<"$top_level_fixture_entry" >/dev/null || fail top_level_derivation_fixture_changed
[[ "$(derivation_input_drv_paths <<<"$wrapped_fixture_entry" | jq -r '.[0]')" == "/nix/store/$fixture_current_dependency" ]] ||
  fail wrapped_derivation_inputs_changed
[[ "$(derivation_input_drv_paths <<<"$top_level_fixture_entry" | jq -r '.[0]')" == "$fixture_legacy_dependency" ]] ||
  fail top_level_derivation_inputs_changed

expect_derivation_rejected() {
  local reason=$1 fixture=$2
  if normalize_derivation_json <<<"$fixture" >/dev/null 2>&1; then
    fail "$reason"
  fi
}

unsupported_version=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_current_drv" \
  '{version:5,derivations:{($drv):$body}}')
expect_derivation_rejected unsupported_derivation_version_accepted "$unsupported_version"
wrapped_absolute_legacy=$(jq -cn --argjson body "$fixture_body_legacy" --arg drv "$fixture_legacy_drv" \
  '{version:4,derivations:{($drv):$body}}')
expect_derivation_rejected wrapped_legacy_internals_accepted "$wrapped_absolute_legacy"
top_level_basename_current=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_current_drv" \
  '{($drv):$body}')
expect_derivation_rejected top_level_current_internals_accepted "$top_level_basename_current"
wrapped_absolute_current=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_legacy_drv" \
  '{version:4,derivations:{($drv):$body}}')
expect_derivation_rejected wrapped_absolute_drv_key_accepted "$wrapped_absolute_current"
top_level_absolute_current=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_legacy_drv" \
  '{($drv):$body}')
expect_derivation_rejected top_level_current_body_accepted "$top_level_absolute_current"

current_absolute_output=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_current_drv" \
  --arg output "$fixture_legacy_output" \
  '{version:4,derivations:{($drv):($body | .outputs.out.path=$output)}}')
expect_derivation_rejected current_absolute_output_accepted "$current_absolute_output"
legacy_basename_output=$(jq -cn --argjson body "$fixture_body_legacy" --arg drv "$fixture_legacy_drv" \
  --arg output "$fixture_current_output" \
  '{($drv):($body | .outputs.out.path=$output)}')
expect_derivation_rejected legacy_basename_output_accepted "$legacy_basename_output"

invalid_current_dependency=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_current_drv" \
  '{version:4,derivations:{($drv):($body | .inputs.drvs={"../dependency.drv":{outputs:["out"]}})}}')
expect_derivation_rejected invalid_current_dependency_accepted "$invalid_current_dependency"
invalid_legacy_dependency=$(jq -cn --argjson body "$fixture_body_legacy" --arg drv "$fixture_legacy_drv" \
  '{($drv):($body | .inputDrvs={"/nix/store/nested/dependency.drv":["out"]})}')
expect_derivation_rejected invalid_legacy_dependency_accepted "$invalid_legacy_dependency"

for invalid_path in '' '.' '..' $'line\nfeed' '/nix/store/' '/nix/store/../escape' '/nix/store/nested/path'; do
  invalid_current=$(jq -cn \
    --argjson body "$fixture_body_current" \
    --arg drv "$fixture_current_drv" \
    --arg path "$invalid_path" \
    '{version:4,derivations:{($drv):($body | .outputs.out.path=$path)}}')
  expect_derivation_rejected invalid_current_output_path_accepted "$invalid_current"
  invalid_legacy=$(jq -cn \
    --argjson body "$fixture_body_legacy" \
    --arg drv "$fixture_legacy_drv" \
    --arg path "$invalid_path" \
    '{($drv):($body | .outputs.out.path=$path)}')
  expect_derivation_rejected invalid_legacy_output_path_accepted "$invalid_legacy"
done

current_with_legacy_inputs=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_current_drv" \
  '{version:4,derivations:{($drv):($body | .inputDrvs={})}}')
expect_derivation_rejected current_alternate_inputs_accepted "$current_with_legacy_inputs"
legacy_with_current_inputs=$(jq -cn --argjson body "$fixture_body_legacy" --arg drv "$fixture_legacy_drv" \
  '{($drv):($body | .inputs={drvs:{}})}')
expect_derivation_rejected legacy_alternate_inputs_accepted "$legacy_with_current_inputs"
current_with_extra_output=$(jq -cn --argjson body "$fixture_body_current" --arg drv "$fixture_current_drv" \
  '{version:4,derivations:{($drv):($body | .outputs.out.alternate="ignored")}}')
expect_derivation_rejected current_alternate_output_accepted "$current_with_extra_output"

ambiguous_wrapped=$(jq -cn --argjson body "$fixture_body_current" \
  '{version:4,derivations:{
    "dddddddddddddddddddddddddddddddd-one.drv":$body,
    "ffffffffffffffffffffffffffffffff-two.drv":$body
  }}')
if normalize_derivation_json <<<"$ambiguous_wrapped" >/dev/null 2>&1; then
  fail ambiguous_wrapped_derivation_accepted
fi
ambiguous_top=$(jq -cn --argjson body "$fixture_body_legacy" \
  '{
    "/nix/store/dddddddddddddddddddddddddddddddd-one.drv":$body,
    "/nix/store/ffffffffffffffffffffffffffffffff-two.drv":$body
  }')
if normalize_derivation_json <<<"$ambiguous_top" >/dev/null 2>&1; then
  fail ambiguous_top_level_derivation_accepted
fi
wrapped_with_extra=$(jq -cn --argjson body "$fixture_body_current" \
  --arg drv "$fixture_current_drv" '{version:4,derivations:{($drv):$body},extra:{}}')
if normalize_derivation_json <<<"$wrapped_with_extra" >/dev/null 2>&1; then
  fail wrapped_derivation_extra_key_accepted
fi

generator_derivation=$(nix show-derivation "$generator_drv") || fail generator_derivation_unavailable
generator_entry=$(normalize_derivation_json <<<"$generator_derivation") || fail generator_derivation_shape
generator_text=$(jq -er '.value.env.text' <<<"$generator_entry") || fail generator_text_unavailable
generator_out=$(jq -er '.output_path' <<<"$generator_entry") || fail generator_output_unavailable
[[ "$generator_exec" == "$generator_out/bin/hostdash-status" ]] || fail generator_exec_not_exact_output

generator_input_drv_paths=$(derivation_input_drv_paths <<<"$generator_entry") || fail generator_input_schema
collector_drv=$(jq -er '
  [.[] | select((split("/")[-1]) | endswith("-hostdash-container-status.drv"))]
  | if length == 1 then .[0] else error("ambiguous collector input") end
' <<<"$generator_input_drv_paths") || fail collector_drv_not_unique
collector_derivation=$(nix show-derivation "$collector_drv") || fail collector_derivation_unavailable
collector_entry=$(normalize_derivation_json <<<"$collector_derivation") || fail collector_derivation_shape
collector_text=$(jq -er '.value.env.text' <<<"$collector_entry") || fail collector_text_unavailable
collector_out=$(jq -er '.output_path' <<<"$collector_entry") || fail collector_output_unavailable
collector_exec="$collector_out/bin/hostdash-container-status"

collector_input_drv_paths=$(derivation_input_drv_paths <<<"$collector_entry") || fail collector_input_schema
jq -e '
  ([.[] | contains("-docker-")] | any)
  and ([.[] | contains("-jq-")] | any)
' <<<"$collector_input_drv_paths" >/dev/null || fail collector_runtime_closure_missing

collector_contract() {
  local source=$1
  grep -Fxq 'set -o errexit' <<<"$source" &&
    grep -Fxq 'set -o nounset' <<<"$source" &&
    grep -Fxq 'set -o pipefail' <<<"$source" &&
    grep -Eq 'export PATH="[^"]*-docker-[^:/]+/bin:' <<<"$source" &&
    grep -Eq 'export PATH="[^"]*-jq-[^:/]+/bin:' <<<"$source" &&
    [[ "$(grep -Fc 'hostdash_collect_containers "$@"' <<<"$source")" == 1 ]]
}
collector_contract "$collector_text" || fail collector_wrapper_contract

without_pipefail=${collector_text/set -o pipefail/}
if collector_contract "$without_pipefail"; then fail collector_pipefail_mutation_accepted; fi
without_docker=$(sed -E 's#/nix/store/[a-z0-9]+-docker-[^:/]+/bin:##' <<<"$collector_text")
if collector_contract "$without_docker"; then fail collector_docker_runtime_mutation_accepted; fi
without_jq=$(sed -E 's#/nix/store/[a-z0-9]+-jq-[^:/]+/bin:##' <<<"$collector_text")
if collector_contract "$without_jq"; then fail collector_jq_runtime_mutation_accepted; fi
body_true=${collector_text/hostdash_collect_containers \"\$@\"/true}
if collector_contract "$body_true"; then fail collector_body_mutation_accepted; fi

# Pin the generator to the exact collector derivation, not merely to a command name
# that happens to be on PATH. Its own strict wrapper and atomic transaction are part
# of the assurance boundary too.
for strict_flag in errexit nounset pipefail; do
  grep -Fxq "set -o $strict_flag" <<<"$generator_text" || fail "generator_${strict_flag}_missing"
done
# Literal generated-shell source pattern.
# shellcheck disable=SC2016
collector_invocation=$(sed -n '/containers="$(.*hostdash-container-status/,/)"/p' <<<"$generator_text")
[[ -n "$collector_invocation" ]] || fail container_collector_invocation_missing
grep -Fq "$collector_exec" <<<"$collector_invocation" || fail generator_not_using_exact_collector
if grep -Eq '\|\||(^|[[:space:]])(echo|true)([[:space:]]|$)' <<<"$collector_invocation"; then
  fail container_collector_invocation_fails_open
fi
# Literal generated-shell source patterns.
# shellcheck disable=SC2016
grep -Fq 'trap '\''rm -f "$TMP"'\'' EXIT' <<<"$generator_text" || fail producer_temp_cleanup_missing
# shellcheck disable=SC2016
grep -Fq 'chmod 0644 "$TMP"' <<<"$generator_text" || fail producer_mode_missing
# shellcheck disable=SC2016
grep -Fq 'mv -f "$TMP" "$OUT"' <<<"$generator_text" || fail producer_atomic_swap_missing

producer_fixture=$(mktemp -d)
cleanup_producer_fixture() {
  find "$producer_fixture" -type f -delete
  find "$producer_fixture" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup_producer_fixture EXIT
fixture_out="$producer_fixture/status.json"
collector_wrapper="$producer_fixture/hostdash-container-status"
printf '%s' "$collector_text" >"$collector_wrapper"
printf '{"sentinel":true}\n' >"$fixture_out"

run_producer_fixture() {
  local docker_status=$1 jq_status=$2
  DOCKER_TEST_STATUS="$docker_status" \
    JQ_TEST_STATUS="$jq_status" \
    REAL_JQ="$(command -v jq)" \
    bash -c '
      set -euo pipefail
      wrapper=$1
      filter=$2
      out=$3
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
      # Invoke the exact evaluated writeShellApplication wrapper under this
      # machine Bash, ignoring only its cross-system shebang.
      containers=$(bash "$wrapper" '\''["allowed","missing"]'\'' "$filter")
      "$REAL_JQ" -n --argjson containers "$containers" '\''{containers:$containers}'\'' >"$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$out"
      trap - EXIT
    ' bash "$collector_wrapper" "$filter" "$fixture_out"
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
