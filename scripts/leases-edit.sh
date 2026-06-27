#!/usr/bin/env bash
#
# leases-edit.sh — edit AdGuard static DHCP leases (agenix-encrypted) with validation.
#
# Wraps `agenix -e secrets/static-leases-<host>.age`, inserting a validation pass
# between your editor and re-encryption so a typo can't silently break DHCP. The
# age file is re-encrypted ONLY if validation passes; aborting leaves it untouched.
#
# Checks:
#   - structural : valid JSON array of {mac, ip, hostname}                 (hard)
#   - MAC        : well-formed (aa:bb:cc:dd:ee:ff), unique                 (hard)
#   - IP         : inside host STATIC range, not gateway, not dynamic pool, unique  (hard)
#   - hostname   : DNS-safe + unique                                       (hard)
#   - naming     : <room>-<device> convention (known room prefix)          (warn only)
#
# Usage:
#   just leases-edit [hsb0|hsb8]     # default hsb0  — decrypt → edit → validate → re-encrypt
#   just leases-check [hsb0|hsb8]    # validate the current encrypted file, no edit
#
# Run from the repo root (the just recipes do this for you).

set -euo pipefail

# --------------------------------------------------------------------------- #
# Per-host network parameters. Static reservations must sit OUTSIDE the dynamic
# pool. hsb0 = AdGuard on 192.168.1.0/24 (gateway .1, dynamic .201-.254).
# --------------------------------------------------------------------------- #
net_params() {
  case "$1" in
  hsb0)
    SUBNET_PREFIX="192.168.1"
    GATEWAY=1
    STATIC_MIN=2
    STATIC_MAX=200
    DYN_MIN=201
    DYN_MAX=254
    ;;
  hsb8)
    echo "✗ hsb8 ranges not yet verified in leases-edit.sh." >&2
    echo "  Confirm hsb8's AdGuard DHCP subnet/pool and add a net_params case first." >&2
    exit 3
    ;;
  *)
    echo "✗ unknown host '$1' (expected hsb0 or hsb8)" >&2
    exit 3
    ;;
  esac
}

ROOM_PREFIXES="vr wz sz ki ku ez bz tg te dt kr vk gz sh wc"
# Non-room infra hostnames that are allowed without a naming warning.
INFRA_RE='^(hsb[0-9]+|csb[0-9]+|gpc[0-9]+|raspi[0-9].*|opusshgw|mbp[0-9].*)$'

legend() {
  cat >&2 <<EOF
─ Room prefixes ───────────────────────────────────────────────────────────────
 vr Vorraum   wz Wohnzimmer  sz Schlafzimmer  ki Kinderzimmer  ku Küche
 ez Esszimmer bz Badezimmer  tg Tiefgarage    te Terrasse      dt Dachterrasse
 kr Kellerraum  vk Vorküche  gz Gästezimmer  sh Stiegenhaus  wc WC
 Convention:  <room>-<vendor/type>-<descr>   e.g. vr-cinnado-cam, kr-nuki-smart-keller
 Static IPs:  ${SUBNET_PREFIX}.${STATIC_MIN}–${STATIC_MAX}   (dynamic pool ${SUBNET_PREFIX}.${DYN_MIN}–${DYN_MAX} is off-limits)
────────────────────────────────────────────────────────────────────────────────
EOF
}

# --------------------------------------------------------------------------- #
# validate <file>  — prints ✗ (hard) / ⚠ (warn) lines; returns 1 if any ✗.
# Relies on SUBNET_PREFIX/GATEWAY/STATIC_*/DYN_* being set in the environment.
# --------------------------------------------------------------------------- #
validate() {
  local f="$1" hard=0

  if ! jq empty "$f" 2>/dev/null; then
    echo "✗ not valid JSON"
    return 1
  fi
  if [ "$(jq -r 'type' "$f")" != "array" ]; then
    echo "✗ top-level must be a JSON array of {mac, ip, hostname}"
    return 1
  fi
  # every element must have the three string fields
  if [ "$(jq '[.[] | select((.mac|type)=="string" and (.ip|type)=="string" and (.hostname|type)=="string")] | length' "$f")" \
    != "$(jq 'length' "$f")" ] 2>/dev/null; then
    echo "✗ every entry needs string mac, ip and hostname"
    return 1
  fi

  # duplicate detection (hard)
  local dups
  dups="$(jq -r '[.[].ip]               | group_by(.)|map(select(length>1))|map(.[0])|.[]' "$f")"
  [ -n "$dups" ] && {
    hard=1
    while read -r x; do echo "✗ duplicate IP: $x"; done <<<"$dups"
  }
  dups="$(jq -r '[.[].mac|ascii_downcase]| group_by(.)|map(select(length>1))|map(.[0])|.[]' "$f")"
  [ -n "$dups" ] && {
    hard=1
    while read -r x; do echo "✗ duplicate MAC: $x"; done <<<"$dups"
  }
  dups="$(jq -r '[.[].hostname]          | group_by(.)|map(select(length>1))|map(.[0])|.[]' "$f")"
  [ -n "$dups" ] && {
    hard=1
    while read -r x; do echo "✗ duplicate hostname: $x"; done <<<"$dups"
  }

  # per-entry field checks
  local mac ip host octet
  while IFS=$'\t' read -r host ip mac; do
    [ -z "$host$ip$mac" ] && continue
    # MAC
    if ! [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
      echo "✗ $host: bad MAC '$mac' (want aa:bb:cc:dd:ee:ff)"
      hard=1
    fi
    # IP shape + range
    if [[ "$ip" != "${SUBNET_PREFIX}."* ]]; then
      echo "✗ $host: IP '$ip' outside subnet ${SUBNET_PREFIX}.0/24"
      hard=1
    else
      octet="${ip##*.}"
      if ! [[ "$octet" =~ ^[0-9]+$ ]]; then
        echo "✗ $host: malformed IP '$ip'"
        hard=1
      elif [ "$octet" -eq "$GATEWAY" ]; then
        echo "✗ $host: IP '$ip' is the gateway"
        hard=1
      elif [ "$octet" -ge "$DYN_MIN" ] && [ "$octet" -le "$DYN_MAX" ]; then
        echo "✗ $host: IP '$ip' is in the dynamic pool (.${DYN_MIN}-.${DYN_MAX}) — pick .${STATIC_MIN}-.${STATIC_MAX}"
        hard=1
      elif [ "$octet" -lt "$STATIC_MIN" ] || [ "$octet" -gt "$STATIC_MAX" ]; then
        echo "✗ $host: IP '$ip' outside static range .${STATIC_MIN}-.${STATIC_MAX}"
        hard=1
      fi
    fi
    # hostname: DNS-safe (hard), naming convention (warn)
    if ! [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "✗ $host: hostname not DNS-safe (lowercase a-z 0-9 '-', no leading/trailing '-')"
      hard=1
    elif [[ "$host" =~ $INFRA_RE ]]; then
      : # infra host, no room prefix expected
    else
      local prefix="${host%%-*}" known=0 p
      for p in $ROOM_PREFIXES; do [ "$prefix" = "$p" ] && known=1 && break; done
      if [ "$known" -ne 1 ] || [ "$prefix" = "$host" ]; then
        echo "⚠ $host: doesn't match <room>-<device> (room prefix one of: $ROOM_PREFIXES)"
      fi
    fi
  done < <(jq -r '.[] | [.hostname, .ip, (.mac // "")] | @tsv' "$f")

  [ "$hard" -eq 0 ]
}

# --------------------------------------------------------------------------- #
# EDITOR mode: agenix calls us as $EDITOR with the decrypted temp file as $1.
# --------------------------------------------------------------------------- #
if [ "${LEASES_EDIT_MODE:-}" = "editor" ]; then
  tmp="$1"
  net_params "${LEASES_NET:-hsb0}"
  orig="$(mktemp)"
  cp "$tmp" "$orig"

  # tidy view: sort by IP, one compact entry per line (clean git diffs; AdGuard ignores layout)
  if jq empty "$tmp" 2>/dev/null; then
    if fmt="$(jq -r '"[\n" + ([ .[] | {hostname,ip,mac} ] | sort_by(.ip|split(".")|map(tonumber)) | map("  "+tojson) | join(",\n")) + "\n]"' "$orig" 2>/dev/null)" && [ -n "$fmt" ]; then
      printf '%s\n' "$fmt" >"$tmp"
    else cp "$orig" "$tmp"; fi
  fi
  legend

  real_ed="${LEASES_REAL_EDITOR:-nano}"
  while true; do
    # shellcheck disable=SC2086
    $real_ed "$tmp"
    if msgs="$(validate "$tmp")"; then
      [ -n "$msgs" ] && printf '%s\n' "$msgs" >&2
      echo "✓ leases valid — agenix will re-encrypt." >&2
      rm -f "$orig"
      exit 0
    fi
    printf '%s\n' "$msgs" >&2
    # Allow forcing a write to override naming/semantic complaints (operator
    # knows best) — BUT never force structurally broken JSON, which would make
    # AdGuard's preStart merge fail on hsb0.
    if jq empty "$tmp" 2>/dev/null; then
      printf 'Validation FAILED. [e] edit again  /  [w] write anyway (override)  /  [a] abort: ' >&2
      force_ok=1
    else
      printf 'Invalid JSON — cannot write (would break AdGuard merge). [e] edit again  /  [a] abort: ' >&2
      force_ok=0
    fi
    read -r ans </dev/tty || ans=a
    case "$ans" in
    a | A)
      cp "$orig" "$tmp"
      rm -f "$orig"
      echo "↩ Aborted — age file unchanged." >&2
      exit 0
      ;;
    w | W) if [ "$force_ok" -eq 1 ]; then
      echo "⚠ Writing despite validation issues (operator override)." >&2
      rm -f "$orig"
      exit 0
    fi ;;   # bad JSON: ignore [w], loop back to edit
    *) : ;; # loop
    esac
  done
fi

# --------------------------------------------------------------------------- #
# CHECK mode: decrypt to a temp file, validate, never edit, never print content.
# --------------------------------------------------------------------------- #
if [ "${1:-}" = "--check" ]; then
  host="${2:-hsb0}"
  net_params "$host"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  agenix -d "secrets/static-leases-${host}.age" >"$tmp"
  if out="$(validate "$tmp")"; then
    [ -n "$out" ] && printf '%s\n' "$out"
    echo "✓ static-leases-${host}: valid"
  else
    printf '%s\n' "$out"
    echo "✗ static-leases-${host}: INVALID" >&2
    exit 1
  fi
  exit 0
fi

# --------------------------------------------------------------------------- #
# TOP-LEVEL (edit) mode: re-exec ourselves as agenix's $EDITOR.
# --------------------------------------------------------------------------- #
host="${1:-hsb0}"
net_params "$host" # fail fast on unknown host before touching agenix
command -v agenix >/dev/null || {
  echo "✗ agenix not found in PATH" >&2
  exit 4
}
command -v jq >/dev/null || {
  echo "✗ jq not found in PATH" >&2
  exit 4
}

export LEASES_EDIT_MODE=editor
export LEASES_NET="$host"
export LEASES_REAL_EDITOR="${VISUAL:-${EDITOR:-nano}}"
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
export EDITOR="$self"
export VISUAL="$self"
exec agenix -e "secrets/static-leases-${host}.age"
