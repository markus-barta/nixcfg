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
pin=136988907cdbba4fa56ebfa6a4dd8cf8ff5f845e

fail() {
  printf 'hostdash_status_fleet=failed reason=%s\n' "$1" >&2
  exit 1
}

for command in nix jq node; do
  command -v "$command" >/dev/null 2>&1 || fail "missing_$command"
done

locked=$(jq -r '.nodes.hostdash.locked.rev' "$repo_root/flake.lock")
[[ "$locked" == "$pin" ]] || fail hostdash_pin_drift
[[ "$(jq -r '.nodes.hostdash.original.repo' "$repo_root/flake.lock")" == hostdash ]] ||
  fail hostdash_original_repo_drift

hostdash_source=$(nix eval --impure --raw --expr \
  "(builtins.getFlake \"path:${flake_ref}\").inputs.hostdash.outPath")
bindings=$(node "$repo_root/tests/hostdash-status-bindings.mjs" "$hostdash_source")

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
