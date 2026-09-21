#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 && $# -ne 8 ]]; then
  echo "usage: $0 HOST ACCENT KIND SUPPRESS_DOWN SUPPRESS_BACKUP SUPPRESS_NIX_FRESHNESS REQUEST_ID [NIXPKGS_WARN_AFTER_DAYS]" >&2
  exit 2
fi

host=$1
accent=$2
kind=$3
suppress_down=$4
suppress_backup=$5
suppress_nix_freshness=$6
request_id=$7
# PHAROS-289: optional per-host nixpkgs staleness threshold in days. Empty
# (or omitted) removes the override so the host inherits the fleet default.
nixpkgs_warn_after_days=${8:-}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
settings_file=${PHAROS_SETTINGS_FILE:-"$repo_root/modules/pharos-host-preferences.json"}

validate_registry() {
  jq -e '
    .schema == "inspr.pharos.host-preferences.v1" and
    .version == 1 and
    ((keys | sort) == ["hosts", "schema", "version"]) and
    (.hosts | type == "object" and length > 0) and
    all(.hosts[];
      ((keys | sort) == ["accent", "alerts", "kind"]) and
      (.accent | type == "string" and test("^#[0-9a-fA-F]{6}$")) and
      (.kind == "server" or .kind == "workstation") and
      ((.alerts | keys | sort) as $alert_keys |
        $alert_keys == ["suppress_backup", "suppress_down", "suppress_nix_freshness"] or
        $alert_keys == ["nixpkgs_warn_after_days", "suppress_backup", "suppress_down", "suppress_nix_freshness"]) and
      ([.alerts.suppress_backup, .alerts.suppress_down, .alerts.suppress_nix_freshness] | all(type == "boolean")) and
      ((.alerts | has("nixpkgs_warn_after_days") | not) or
        (.alerts.nixpkgs_warn_after_days | type == "number" and . == floor and . >= 1 and . <= 3650))
    )
  ' "$1" >/dev/null
}

[[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || {
  echo "host must be a lowercase fleet hostname" >&2
  exit 2
}
[[ "$accent" =~ ^#[0-9a-fA-F]{6}$ ]] || {
  echo "accent must be a six-digit hex color" >&2
  exit 2
}
[[ "$kind" == "server" || "$kind" == "workstation" ]] || {
  echo "kind must be server or workstation" >&2
  exit 2
}
for value in "$suppress_down" "$suppress_backup" "$suppress_nix_freshness"; do
  [[ "$value" == "true" || "$value" == "false" ]] || {
    echo "alert preferences must be true or false" >&2
    exit 2
  }
done
if [[ -n "$nixpkgs_warn_after_days" ]]; then
  if ! [[ "$nixpkgs_warn_after_days" =~ ^[0-9]{1,4}$ ]] ||
    ((10#$nixpkgs_warn_after_days < 1 || 10#$nixpkgs_warn_after_days > 3650)); then
    echo "nixpkgs warning threshold must be a whole number of days from 1 to 3650" >&2
    exit 2
  fi
fi
[[ "$request_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$ ]] || {
  echo "request id contains unsupported characters" >&2
  exit 2
}

validate_registry "$settings_file"
jq -e --arg host "$host" '.hosts | has($host)' "$settings_file" >/dev/null || {
  echo "host is not declared in the Pharos settings registry" >&2
  exit 3
}

next=$(mktemp "${settings_file}.tmp.XXXXXX")
jq -S \
  --arg host "$host" \
  --arg accent "$accent" \
  --arg kind "$kind" \
  --argjson suppress_down "$suppress_down" \
  --argjson suppress_backup "$suppress_backup" \
  --argjson suppress_nix_freshness "$suppress_nix_freshness" \
  --arg nixpkgs_warn_after_days "$nixpkgs_warn_after_days" \
  '.hosts[$host] = {
    accent: ($accent | ascii_downcase),
    alerts: ({
      suppress_backup: $suppress_backup,
      suppress_down: $suppress_down,
      suppress_nix_freshness: $suppress_nix_freshness
    } + (if $nixpkgs_warn_after_days == "" then {}
         else {nixpkgs_warn_after_days: ($nixpkgs_warn_after_days | tonumber)} end)),
    kind: $kind
  }' \
  "$settings_file" >"$next"
validate_registry "$next"
mv "$next" "$settings_file"

printf 'updated=%s request=%s\n' "$host" "$request_id"
