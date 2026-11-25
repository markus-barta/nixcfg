#!/usr/bin/env bash
# HAUSV-918 / OPS-675: no builds, containers, host access or external requests.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

nix-instantiate --eval --strict --json --expr 'import ./tests/hausv-pause-eval.nix {}'
printf '\nHAUSV placeholder scoped evaluation: OK\n'

must_fail() {
  local name="$1" expression="$2" output
  if output="$(nix-instantiate --eval --strict --json --expr "$expression" 2>&1)"; then
    printf 'FAIL: %s mutant passed\n' "$name" >&2
    exit 1
  fi
  # A missing dependency or syntax error is not evidence of mutant rejection.
  if ! printf '%s\n' "$output" | grep -q 'assertion.*failed'; then
    printf 'FAIL: %s failed without the contract assertion\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  printf 'HAUSV must-fail mutant (%s): rejected\n' "$name"
}

must_fail 'default router priority' '
  let
    spec = import ./hosts/csb1/docker/compose-spec.nix;
    pause = spec.services.hausv-pause;
  in import ./tests/hausv-pause-eval.nix {
    spec = spec // { services = spec.services // { hausv-pause = pause // {
      labels = builtins.filter (label:
        label != "traefik.http.routers.hausv-pause.priority=1"
        && label != "traefik.http.routers.hausv-pause-http.priority=1"
      ) pause.labels;
    }; }; };
  }'

must_fail 'changed page byte' '
  import ./tests/hausv-pause-eval.nix {
    pageContents = builtins.substring 0 1311
      (builtins.readFile ./hosts/csb1/docker/hausv-pause/index.html) + " ";
  }'

must_fail 'unrelated container removed' '
  let spec = import ./hosts/csb1/docker/compose-spec.nix;
  in import ./tests/hausv-pause-eval.nix {
    spec = spec // { services = builtins.removeAttrs spec.services ["docmost"]; };
  }'
