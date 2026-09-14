#!/usr/bin/env bash
# NIX-501: merge the published routing compiler output with csb1's reviewed
# legacy compatibility library. Both inputs are value-free.
set -euo pipefail

output=${1:?output path required}
compiled=${2:?compiled routing fragment required}
legacy=${3:?legacy routing fragment required}
namespace=${4:?routing namespace required}

for input in "${compiled}" "${legacy}"; do
  if [[ ! -r ${input} || -L ${input} ]]; then
    printf '%s\n' 'shared Flow routing blocked: an input fragment is missing, unreadable, or a symlink' >&2
    exit 1
  fi
done

output_dir=$(dirname -- "${output}")
if [[ ! -d ${output_dir} ]]; then
  printf '%s\n' 'shared Flow routing blocked: private runtime directory is missing' >&2
  exit 1
fi

for section in routers middlewares services serversTransports; do
  collision=$(
    comm -12 \
      <(yq eval -r ".http.${section} // {} | keys | .[]" "${compiled}" | sort -u) \
      <(yq eval -r ".http.${section} // {} | keys | .[]" "${legacy}" | sort -u) |
      head -n 1
  )
  if [[ -n ${collision} ]]; then
    printf 'shared Flow routing blocked: %s resource collision\n' "${section}" >&2
    exit 1
  fi
done

umask 022
temporary=$(mktemp "${output}.tmp.XXXXXX")
cleanup() {
  rm -f -- "${temporary}"
}
trap cleanup EXIT HUP INT TERM

# The yq expression is intentionally literal; $item belongs to yq, not Bash.
# shellcheck disable=SC2016
yq eval-all '. as $item ireduce ({}; . * $item)' "${compiled}" "${legacy}" >"${temporary}"

# Keep the existing Cloudflare source canonicalization in front of every new
# browser-visible compiler route. The compiler-owned identity-dropping chain
# remains immediately after it; legacy-flow-routing.nix already applies the
# same middleware to its public compatibility routes.
for router in \
  "${namespace}-app-aithema" \
  "${namespace}-app-paimos" \
  "${namespace}-app-pharos" \
  "${namespace}-app-janus" \
  "${namespace}-landing"; do
  if ! yq eval -e ".http.routers.\"${router}\"" "${temporary}" >/dev/null; then
    printf '%s\n' 'shared Flow routing blocked: compiler output omitted a required public router' >&2
    exit 1
  fi
  yq eval -i ".http.routers.\"${router}\".middlewares = ([\"cloudflarewarp@file\"] + .http.routers.\"${router}\".middlewares)" "${temporary}"
done

for router in inspr-legacy-paimos-proxy inspr-legacy-pharos-proxy inspr-legacy-janus-proxy; do
  if ! yq eval -e ".http.routers.\"${router}\"" "${temporary}" >/dev/null; then
    printf '%s\n' 'shared Flow routing blocked: legacy compatibility routes are incomplete' >&2
    exit 1
  fi
done

chmod 0444 "${temporary}"
mv -f -- "${temporary}" "${output}"
trap - EXIT HUP INT TERM
printf '%s\n' 'shared_flow_routing=ready value_returned=false'
