#!/usr/bin/env bash
# T75 — pin csb1 Traefik 3.7.13 and prove providers/plugin/redirect in
# isolated Linux containers (NIX-448).
#
# Source checks describe the host compose/static/dynamic boundary.
# Runtime checks start a disposable network and containers: no host
# published ports, no production mounts, no secrets, no ACME issuance.
# Missing Docker is fail-closed; root can rerun this same script.
set -euo pipefail

report_failure() {
  local line=$1
  local exit_code=$2
  printf 'T75: failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO" "$?"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
static="$repo_root/hosts/csb1/docker/traefik/static.yml"
dynamic="$repo_root/hosts/csb1/docker/traefik/dynamic.yml"
host_config="$repo_root/hosts/csb1/configuration.nix"

TRAEFIK_IMAGE='traefik:v3.7.13@sha256:f86a2cab1b5c649070c49f883c743dd32d8485a56e3368c5f93b9e91f1e91259'
TRAEFIK_INDEX_DIGEST='sha256:f86a2cab1b5c649070c49f883c743dd32d8485a56e3368c5f93b9e91f1e91259'
ALPINE_IMAGE='alpine:3.22.5@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce'
PROXY_IMAGE='tecnativa/docker-socket-proxy@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459'
WHOAMI_IMAGE='traefik/whoami:v1.11.0@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab'

PREFIX='nix448-t75'
NET="${PREFIX}-net"
PROXY="${PREFIX}-proxy"
EDGE="${PREFIX}-traefik"
BACKEND="${PREFIX}-backend"

# --- 1. host source boundary ----------------------------------------------
for file in "$compose" "$static" "$dynamic" "$host_config"; do
  [ -f "$file" ]
done

if grep -Fq 'image = "traefik";' "$compose"; then
  printf 'T75: csb1 Traefik image is still the unpinned floating tag\n' >&2
  exit 1
fi
grep -Fq "image = \"${TRAEFIK_IMAGE}\"" "$compose"
grep -Fq 'command = "--configFile=/etc/traefik/traefik.yml"' "$compose"
if grep -Fq 'command = "--providers.docker"' "$compose"; then
  printf 'T75: Traefik still takes a CLI provider flag beside static config\n' >&2
  exit 1
fi

grep -Fq 'image = "tecnativa/docker-socket-proxy"' "$compose"
grep -Fq 'endpoint: "tcp://docker-proxy-traefik:2375"' "$static"
grep -Fq 'directory: /etc/traefik/dynamic' "$static"
grep -Fq 'watch: true' "$static"
grep -Fq 'modulename: github.com/BetterCorp/cloudflarewarp' "$static"
grep -Fq 'version: v1.3.3' "$static"
grep -Fq 'http3: {}' "$static"
grep -Fq 'dashboard: false' "$static"
grep -Fq 'storage: /etc/traefik/acme/acme.json' "$static"
grep -Fq 'storage: /etc/traefik/acme/acme-http.json' "$static"
grep -Fq 'public-http:' "$static"
grep -Fq '(privateBind "/run/inspr-edge/dynamic.yml" "/etc/traefik/dynamic/inspr-edge.yml")' "$compose"
grep -Fq '"80:80"' "$compose"
grep -Fq '"443:443/tcp"' "$compose"
grep -Fq '"443:443/udp"' "$compose"

# shellcheck disable=SC2016 # literal Traefik rule bytes, not shell expansion
grep -Fq 'HostRegexp(`^.+\\.barta\\.cm$`)' "$dynamic"
if grep -Fq '{subdomain:' "$dynamic"; then
  printf 'T75: dynamic.yml still uses v2 HostRegexp placeholders\n' >&2
  exit 1
fi
# shellcheck disable=SC2016 # literal Traefik Host matcher, not shell expansion
grep -Fq 'Host(`hausv.org`)' "$dynamic"
grep -Fq 'cloudflarewarp:' "$dynamic"
grep -Fq 'redirectScheme:' "$dynamic"

if grep -Eq 'existingTraefikVersion[[:space:]]*=' "$host_config"; then
  printf 'T75: host config claims existingTraefikVersion before the public consumer pin matches\n' >&2
  exit 1
fi
if grep -Eq 'services\.inspr\.routingEdge\.enable[[:space:]]*=[[:space:]]*true' "$host_config"; then
  printf 'T75: routing-edge consumer was activated\n' >&2
  exit 1
fi

# --- 2. isolated runtime --------------------------------------------------
if ! docker info >/dev/null 2>&1; then
  printf 'T75: docker unavailable; fail closed. Root command: tests/T75-csb1-traefik-3713-isolated.sh\n' >&2
  exit 1
fi

cleanup() {
  docker rm -f "$EDGE" "$BACKEND" "$PROXY" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
on_err() {
  local status=$?
  local line=$1
  cleanup
  report_failure "$line" "$status"
  exit "$status"
}
trap 'on_err "$LINENO"' ERR
trap cleanup EXIT

cleanup

# Workspace path, not /tmp: Docker Desktop on macOS often turns missing
# /tmp file binds into directories inside the VM.
work="$repo_root/tests/.tmp/${PREFIX}"
mkdir -p "$work/dynamic" "$work/acme"
: >"$work/acme/acme.json"
: >"$work/acme/acme-http.json"
chmod 600 "$work/acme/acme.json" "$work/acme/acme-http.json"

cat >"$work/static.yml" <<'EOF'
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO

experimental:
  plugins:
    cloudflarewarp:
      modulename: github.com/BetterCorp/cloudflarewarp
      version: v1.3.3

entryPoints:
  web:
    address: ":80"
  web-secure:
    address: ":443"
    http3: {}

ping:
  entryPoint: web

providers:
  docker:
    endpoint: "tcp://nix448-t75-proxy:2375"
    watch: true
    exposedByDefault: false
    constraints: "Label(`nix448.proof`,`true`)"
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  default:
    acme:
      email: isolated-proof@example.test
      storage: /etc/traefik/acme/acme.json
      caServer: https://127.0.0.1:1/directory
      dnsChallenge:
        provider: cloudflare
        delayBeforeCheck: 0
  public-http:
    acme:
      email: isolated-proof@example.test
      storage: /etc/traefik/acme/acme-http.json
      caServer: https://127.0.0.1:1/directory
      httpChallenge:
        entryPoint: web

api:
  dashboard: false
EOF

cat >"$work/dynamic/dynamic.yml" <<'EOF'
http:
  routers:
    https-redirect:
      rule: "HostRegexp(`^.+\\.example\\.test$`)"
      entryPoints:
        - web
      middlewares:
        - https-redirect
      service: redirect-all
      priority: 1
  middlewares:
    https-redirect:
      redirectScheme:
        scheme: https
    cloudflarewarp:
      plugin:
        cloudflarewarp:
          disableDefault: false
          trustip:
            - "172.16.0.0/12"
            - "2400:cb00::/32"
  services:
    redirect-all:
      loadBalancer:
        servers:
          - url: ""
EOF

docker pull "$TRAEFIK_IMAGE" >/dev/null
docker pull "$ALPINE_IMAGE" >/dev/null
docker pull "$PROXY_IMAGE" >/dev/null
docker pull "$WHOAMI_IMAGE" >/dev/null

version_out=$(docker run --rm --network none --entrypoint traefik "$TRAEFIK_IMAGE" version)
printf '%s\n' "$version_out" | grep -Fq 'Version:      3.7.13'

docker network create --driver bridge --internal=false "$NET" >/dev/null

docker run -d --name "$PROXY" --network "$NET" --network-alias nix448-t75-proxy \
  --restart=no \
  -e CONTAINERS=1 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --label nix448.proof=skip \
  "$PROXY_IMAGE" >/dev/null

docker run -d --name "$BACKEND" --network "$NET" --network-alias nix448-t75-backend \
  --restart=no \
  --label nix448.proof=true \
  --label traefik.enable=true \
  --label 'traefik.http.routers.nix448backend.rule=Host(`backend.example.test`)' \
  --label traefik.http.routers.nix448backend.entrypoints=web \
  --label traefik.http.routers.nix448backend.middlewares=cloudflarewarp@file \
  --label traefik.http.services.nix448backend.loadbalancer.server.port=80 \
  --label traefik.docker.network="$NET" \
  "$WHOAMI_IMAGE" >/dev/null

[ -f "$work/static.yml" ]
[ -f "$work/dynamic/dynamic.yml" ]

docker run -d --name "$EDGE" --network "$NET" --network-alias nix448-t75-traefik \
  --restart=no \
  -v "$work/static.yml:/etc/traefik/traefik.yml:ro" \
  -v "$work/dynamic:/etc/traefik/dynamic:ro" \
  -v "$work/acme:/etc/traefik/acme" \
  --tmpfs /plugins-storage:uid=65532,gid=65532,mode=0755 \
  --label nix448.proof=skip \
  "$TRAEFIK_IMAGE" \
  --configFile=/etc/traefik/traefik.yml >/dev/null

ready=0
i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  if docker run --rm --network "$NET" "$ALPINE_IMAGE" \
    wget -q -T 3 -O /dev/null "http://nix448-t75-traefik/ping" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  docker logs "$EDGE" >&2 || true
  printf 'T75: Traefik ping never became ready\n' >&2
  exit 1
fi

docker logs "$EDGE" >"$work/traefik.log" 2>&1 || true
python3 - "$work/traefik.log" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(re.sub(r"\x1b\[[0-9;]*m", "", path.read_text(errors="replace")), encoding="utf-8")
PY
logs=$(cat "$work/traefik.log")
printf '%s\n' "$logs" | grep -Fq 'Loading plugins'
printf '%s\n' "$logs" | grep -Fq 'Plugins loaded'
printf '%s\n' "$logs" | grep -Fq 'cloudflarewarp'
printf '%s\n' "$logs" | grep -Fq 'Starting provider *file.Provider'
printf '%s\n' "$logs" | grep -Fq 'Starting provider *docker.Provider'
printf '%s\n' "$logs" | grep -Fq '*acme.Provider'
printf '%s\n' "$logs" | grep -Fq 'providerName=default.acme'
printf '%s\n' "$logs" | grep -Fq 'providerName=public-http.acme'
printf '%s\n' "$logs" | grep -Fq 'acmeCA=https://127.0.0.1:1/directory'

if printf '%s\n' "$logs" | grep -Eqi 'Certificate obtained|Registering account.*success'; then
  printf 'T75: isolated proof issued or registered an ACME certificate\n' >&2
  cat "$work/traefik.log" >&2
  exit 1
fi

docker run --rm --network container:"$EDGE" "$ALPINE_IMAGE" \
  grep -q 01BB /proc/net/udp6

redirect_headers=$(docker run --rm --network "$NET" "$ALPINE_IMAGE" \
  wget -S -T 5 -O /dev/null --header 'Host: app.example.test' \
  "http://nix448-t75-traefik/" 2>&1 || true)
printf '%s\n' "$redirect_headers" | grep -Eq 'HTTP/1\.[01] 30[1278]'
printf '%s\n' "$redirect_headers" | grep -Eqi 'Location: https://app\.example\.test'

multi_headers=$(docker run --rm --network "$NET" "$ALPINE_IMAGE" \
  wget -S -T 5 -O /dev/null --header 'Host: foo.bar.example.test' \
  "http://nix448-t75-traefik/" 2>&1 || true)
printf '%s\n' "$multi_headers" | grep -Eq 'HTTP/1\.[01] 30[1278]'
printf '%s\n' "$multi_headers" | grep -Eqi 'Location: https://foo\.bar\.example\.test'

backend_body=$(docker run --rm --network "$NET" "$ALPINE_IMAGE" \
  wget -q -T 8 -O - \
  --header 'Host: backend.example.test' \
  --header 'CF-Connecting-IP: 203.0.113.9' \
  --header 'X-Is-Trusted: spoofed' \
  "http://nix448-t75-traefik/")
printf '%s\n' "$backend_body" | grep -Fq 'X-Is-Trusted: yes'
printf '%s\n' "$backend_body" | grep -Eqi 'X-Real-Ip: 203\.0\.113\.9'
printf '%s\n' "$backend_body" | grep -Fq '203.0.113.9'
if printf '%s\n' "$backend_body" | grep -Fq 'X-Is-Trusted: spoofed'; then
  printf 'T75: plugin left a spoofed trusted header in place\n' >&2
  exit 1
fi

if [ -s "$work/acme/acme.json" ] && grep -Eq '"Certificates"|certificate' "$work/acme/acme.json"; then
  printf 'T75: ACME storage gained a certificate during the isolated proof\n' >&2
  exit 1
fi

printf 'csb1_traefik_3713_isolated=passed version=3.7.13 index_digest=%s\n' "$TRAEFIK_INDEX_DIGEST"
