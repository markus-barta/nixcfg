#!/usr/bin/env bash
# NIX-400: render the secret-bearing Traefik fragment outside the Nix store.
set -euo pipefail

output=${1:?output path required}
token=${ENTER_EDGE_TOKEN:-}

if [[ ! ${token} =~ ^[0-9a-f]{64}$ ]]; then
  printf '%s\n' 'inspr edge config blocked: ENTER_EDGE_TOKEN must be exactly 64 lowercase hex characters' >&2
  exit 1
fi

output_dir=$(dirname -- "${output}")
if [[ ! -d ${output_dir} ]]; then
  printf '%s\n' 'inspr edge config blocked: private runtime directory is missing' >&2
  exit 1
fi

umask 077
temporary=$(mktemp "${output}.tmp.XXXXXX")
cleanup() {
  rm -f -- "${temporary}"
}
trap cleanup EXIT HUP INT TERM

{
  printf '%s\n' \
    'http:' \
    '  middlewares:' \
    '    inspr-auth-edge-token:' \
    '      headers:' \
    '        customRequestHeaders:'
  printf '          X-Inspr-Edge-Token: "%s"\n' "${token}"
} >"${temporary}"

chmod 0400 "${temporary}"
mv -f -- "${temporary}" "${output}"
trap - EXIT HUP INT TERM
printf '%s\n' 'inspr_edge_config=ready value_returned=false'
