#!/usr/bin/env bash
# NIX-343: HostDash receives the HTTP status that an opaque browser probe
# cannot observe. The host probe must stay loopback-only, bounded, and honest
# about a service that returned no response.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old; run under bash 5\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/hostdash-status.nix"
probe="$repo_root/modules/files/hostdash-http-probe.sh"
workflow="$repo_root/.github/workflows/check.yml"
escape_fixture="$repo_root/tests/hostdash-http-escape-eval.nix"

fail() {
  printf 'hostdash_http_status=failed reason=%s\n' "$1" >&2
  exit 1
}

[[ -f "$probe" ]] || fail missing_probe_helper

# Drive the real helper with a shell-function curl stub. This keeps the oracle
# offline while proving the exact success, 5xx, no-response and malformed-output
# behaviour. jq is real because it is also a declared runtime dependency.
run_probe() {
  local output=$1 status=$2 url=$3
  PROBE_OUTPUT="$output" PROBE_STATUS="$status" bash -c '
    curl() {
      printf "%s" "$PROBE_OUTPUT"
      return "$PROBE_STATUS"
    }
    export -f curl
    source "$1" "$2"
  ' bash "$probe" "$url"
}

[[ "$(run_probe '200 0.011000' 0 'https://127.0.0.1:10443/')" == '{"code":200,"ms":11}' ]] ||
  fail success_shape
[[ "$(run_probe '503 0.547150' 0 'http://127.0.0.1:8123/')" == '{"code":503,"ms":547}' ]] ||
  fail failure_status_preserved
[[ "$(run_probe '000 3.000000' 28 'http://127.0.0.1:1880/')" == '{"code":0,"ms":0}' ]] ||
  fail no_response_not_zero_http_success
[[ "$(run_probe 'not-a-curl-result' 0 'http://127.0.0.1:1880/')" == '{"code":0,"ms":0}' ]] ||
  fail malformed_output_fail_closed
if run_probe '200 0.001000' 0 'https://hsb1.lan:10443/' >/dev/null 2>&1; then
  fail lan_url_accepted
fi
quoted_url="http://127.0.0.1:8123/it's?arg=\$(printf injected)"
[[ "$(run_probe '200 0.001000' 0 "$quoted_url")" == '{"code":200,"ms":1}' ]] ||
  fail safe_loopback_url_rejected

# Exercise the exact escaping primitive used by the Nix generator. If quoting
# regresses, eval executes the harmless command substitution and the captured
# argument no longer equals the literal URL.
escaped_url=$(nix eval --raw --file "$escape_fixture")
observed_url="$({ ESCAPED_URL="$escaped_url" bash -c '
  hostdash-http-probe() { printf "%s" "$1"; }
  eval "hostdash-http-probe $ESCAPED_URL"
'; })"
[[ "$observed_url" == "$quoted_url" ]] || fail generated_shell_url_injection

# The helper itself must pin the safety arguments. Merely documenting them in
# the option would not stop a later generator edit from probing the LAN or
# stalling the 60-second oneshot.
grep -Fq -- '--insecure' "$probe" || fail missing_self_signed_loopback_support
probe_budget_is_pinned() {
  local source=$1
  [[ "$(grep -Ec -- '--max-time[[:space:]]+[0-9]+' <<<"$source")" == 1 ]] &&
    grep -Eq -- '--max-time[[:space:]]+3([^0-9]|$)' <<<"$source"
}
probe_source=$(<"$probe")
probe_budget_is_pinned "$probe_source" || fail probe_budget_not_pinned
for unbounded_budget in 30 300; do
  mutated_source="${probe_source/--max-time 3/--max-time $unbounded_budget}"
  if probe_budget_is_pinned "$mutated_source"; then
    fail "probe_budget_${unbounded_budget}_accepted"
  fi
done
grep -Fq -- "'%{http_code} %{time_total}'" "$probe" || fail curl_result_contract_missing
grep -Eq '\^https\?://127\\\.0\\\.0\\\.1' "$probe" || fail helper_not_loopback_closed

# Nix owns the closed option and rejects non-loopback configuration at eval
# time. The generator consumes the tested helper and omits the new key for an
# empty map, preserving the pre-NIX-343 artifact shape.
grep -Fq 'httpProbes = lib.mkOption {' "$module" || fail option_missing
grep -Fq 'type = lib.types.attrsOf lib.types.str;' "$module" || fail option_not_closed_map
grep -Fq 'hostdash-http-probe.sh' "$module" || fail tested_helper_not_consumed
grep -Fq 'cfg.httpProbes' "$module" || fail option_not_consumed
grep -Fq "hostdash-http-probe \${lib.escapeShellArg url}" "$module" ||
  fail generator_url_not_shell_escaped
grep -Fq -- "--arg key \${lib.escapeShellArg key}" "$module" ||
  fail generator_key_not_shell_escaped
grep -Fq "if (\$http | length) > 0 then { http: \$http } else { } end" "$module" ||
  fail empty_map_changes_artifact
grep -Fq 'must use an http://127.0.0.1 or https://127.0.0.1 URL' "$module" ||
  fail evaluation_guard_missing
grep -Fq 'keys must be container or unit names' "$module" || fail key_guard_missing

# Both declared host maps must use literal loopback URLs, and every configured
# key must be unique. This accounts for the complete NIX-343 rollout set.
for host in hsb0 hsb1; do
  config="$repo_root/hosts/$host/configuration.nix"
  block=$(sed -n '/httpProbes = {/,/^[[:space:]]*};/p' "$config")
  [[ -n "$block" ]] || fail "$host-probe-map-missing"
  if grep -Ev '^[[:space:]]*(httpProbes = \{|};|#|$|("?[a-zA-Z0-9_.-]+"? = "https?://127\.0\.0\.1:[0-9]+/[^\"]*";))$' <<<"$block" | grep -q .; then
    fail "$host-non-loopback-probe"
  fi
done

[[ "$(sed -n '/httpProbes = {/,/^[[:space:]]*};/p' "$repo_root/hosts/hsb0/configuration.nix" | grep -c '127\.0\.0\.1')" == 4 ]] ||
  fail hsb0_probe_count
[[ "$(sed -n '/httpProbes = {/,/^[[:space:]]*};/p' "$repo_root/hosts/hsb1/configuration.nix" | grep -c '127\.0\.0\.1')" == 10 ]] ||
  fail hsb1_probe_count

expected_probes=(
  'hsb0|"adguardhome.service" = "http://127.0.0.1:3000/";'
  'hsb0|ncps = "http://127.0.0.1:8501/";'
  'hsb0|openclaw-gateway = "https://127.0.0.1:18789/";'
  'hsb0|speedtest-tracker = "http://127.0.0.1:8765/";'
  'hsb1|scrypted = "https://127.0.0.1:10443/";'
  'hsb1|homeassistant = "http://127.0.0.1:8123/";'
  'hsb1|nodered = "http://127.0.0.1:1880/";'
  'hsb1|zigbee2mqtt = "http://127.0.0.1:8888/";'
  'hsb1|opusweb = "http://127.0.0.1:3102/";'
  'hsb1|plex = "http://127.0.0.1:32400/web";'
  'hsb1|pixdcon = "http://127.0.0.1:8080/";'
  'hsb1|funkeykid = "http://127.0.0.1:8081/";'
  'hsb1|apprise = "http://127.0.0.1:8001/";'
  'hsb1|fritz-tripwire = "http://127.0.0.1:9000/";'
)
for expected in "${expected_probes[@]}"; do
  host=${expected%%|*}
  declaration=${expected#*|}
  grep -Fq "$declaration" "$repo_root/hosts/$host/configuration.nix" ||
    fail "$host-declared-probe-missing"
done

[[ "$(grep -Fc 'run: tests/T52-hostdash-http-status.sh' "$workflow")" == 1 ]] ||
  fail ci_wiring_count

printf 'hostdash_http_status=ok probes=%s\n' 14
