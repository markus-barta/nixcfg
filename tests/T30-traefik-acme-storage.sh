#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$repo_root/hosts/csb1/configuration.nix"
compose="$repo_root/hosts/csb1/docker/docker-compose.yml"
ignore="$repo_root/hosts/csb1/docker/.gitignore"

grep -Fq 'composeRoot = "/home/mba/Code/nixcfg/hosts/csb1/docker";' "$config"
# These patterns intentionally match literal Nix interpolation.
# shellcheck disable=SC2016
grep -Fq '"f ${composeRoot}/traefik/acme.json 0600 root root -"' "$config"
# shellcheck disable=SC2016
grep -Fq '"f ${composeRoot}/traefik/acme-http.json 0600 root root -"' "$config"

grep -Fq './traefik/acme.json:/etc/traefik/acme/acme.json:rw' "$compose"
grep -Fq './traefik/acme-http.json:/etc/traefik/acme/acme-http.json:rw' "$compose"

grep -Fxq 'traefik/acme.json' "$ignore"
grep -Fxq 'traefik/acme-http.json' "$ignore"

printf 'ok: Traefik ACME bind sources are private, ignored, and pre-created\n'
