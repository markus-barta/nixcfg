#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
  echo "usage: $0 HOST ACCENT KIND SUPPRESS_DOWN SUPPRESS_BACKUP SUPPRESS_NIX_FRESHNESS REQUEST_ID" >&2
  exit 2
fi

host=$1
accent=$2
kind=$3
suppress_down=$4
suppress_backup=$5
suppress_nix_freshness=$6
request_id=$7

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
      ((.alerts | keys | sort) == ["suppress_backup", "suppress_down", "suppress_nix_freshness"]) and
      all(.alerts[]; type == "boolean")
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
  '.hosts[$host] = {
    accent: ($accent | ascii_downcase),
    alerts: {
      suppress_backup: $suppress_backup,
      suppress_down: $suppress_down,
      suppress_nix_freshness: $suppress_nix_freshness
    },
    kind: $kind
  }' \
  "$settings_file" >"$next"
validate_registry "$next"
mv "$next" "$settings_file"

printf 'updated=%s request=%s\n' "$host" "$request_id"
