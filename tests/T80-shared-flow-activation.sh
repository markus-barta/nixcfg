#!/usr/bin/env bash
# T80 — NIX-501 coherent opt-in shared Flow activation contract.
# Pure/static only: never evaluates or builds a NixOS configuration.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'shared Flow activation test failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/hosts/csb1/shared-flow.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
renderer="$repo_root/hosts/csb1/scripts/render-shared-flow-config.sh"
legacy="$repo_root/hosts/csb1/legacy-flow-routing.nix"
traefik_static="$repo_root/hosts/csb1/docker/traefik/static.yml"

for file in "$helper" "$host_config" "$compose" "$renderer" "$legacy" "$traefik_static"; do
  [[ -f $file ]]
done
command -v jq >/dev/null
command -v yq >/dev/null

for file in "$helper" "$host_config" "$compose"; do
  nix-instantiate --parse "$file" >/dev/null
done
bash -n "$renderer"

work=$(mktemp -d)
cleanup() {
  rm -f -- \
    "$work/contract.json" \
    "$work/deployment.json" \
    "$work/legacy.json" \
    "$work/collision.yml" \
    "$work/merged.yml" \
    "$work/projection.json" \
    "$work/rendered/dynamic.yml" \
    "$work/rendered/wiring-report.json"
  rmdir -- "$work/rendered" "$work" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

nix-instantiate --eval --strict --json --expr "
  let
    lib = import <nixpkgs/lib>;
    f = import ${helper};
    activeRoutingEdge = lib.recursiveUpdate {
      enable = true;
      deploymentMode = \"external-file-provider\";
      allowUnpinnedTraefik = false;
      entrypoint.name = \"web-secure\";
      external = {
        certificateResolver = \"public-http\";
        resourceNamespace = \"inspr-routing-edge\";
        providerFile = \"traefik/dynamic/inspr-routing-edge.yml\";
      };
    } (builtins.removeAttrs f.routingEdgeActivation [ \"contractFile\" ]);
  in {
    inherit (f) active basePaths browserUrls contract machineOrigins network ports privateSourceRanges publicHost publicOrigin;
    aithema = f.aithema;
    inherit activeRoutingEdge;
  }
" >"$work/projection.json"

jq -e '
  .active == true
  and .publicHost == "flow.inspr.at"
  and .publicOrigin == "https://flow.inspr.at"
  and .basePaths == {aithema:"/aithema",janus:"/janus",paimos:"/paimos",pharos:"/pharos"}
  and .browserUrls == {
    aithema:"https://flow.inspr.at/aithema",
    janus:"https://flow.inspr.at/janus",
    paimos:"https://flow.inspr.at/paimos",
    pharos:"https://flow.inspr.at/pharos"
  }
  and .network.subnet == "10.253.253.0/28"
  and .network.gateway == "10.253.253.1"
  and .network.addresses == {
    host:"10.253.253.1",
    janus:"10.253.253.3",
    paimos:"10.253.253.4",
    pharos:"10.253.253.5",
    traefik:"10.253.253.2"
  }
  and .machineOrigins == {janus:"https://vault.barta.cm",pharos:"https://pharos.barta.cm"}
  and .privateSourceRanges.janus == ["10.253.253.1/32"]
  and .privateSourceRanges.pharos == ["10.253.253.3/32"]
  and .aithema.configFile == "/run/aithema-workspace-config.json"
  and .activeRoutingEdge == {
    allowUnpinnedTraefik:false,
    deploymentMode:"external-file-provider",
    enable:true,
    entrypoint:{name:"web-secure"},
    external:{
      certificateResolver:"public-http",
      existingTraefikVersion:"3.7.13",
      providerFile:"traefik/dynamic/inspr-routing-edge.yml",
      resourceNamespace:"inspr-routing-edge"
    },
    upstreams:{
      aithema:{url:"http://10.253.253.1:8787"},
      janus:{url:"http://10.253.253.3:8080"},
      paimos:{url:"http://10.253.253.4:8888"},
      pharos:{url:"http://10.253.253.5:8080"}
    }
  }
' "$work/projection.json" >/dev/null

yq eval -e '
  .certificatesResolvers.public-http.acme.storage == "/etc/traefik/acme/acme-http.json"
  and .certificatesResolvers.public-http.acme.httpChallenge.entryPoint == "web"
' "$traefik_static" >/dev/null

jq '.contract' "$work/projection.json" >"$work/contract.json"
python3 "$repo_root/doctrine/contracts/routing/validate.py" "$work/contract.json" >/dev/null

jq '{
  mode:"external-file-provider",
  entrypoint:{name:"web-secure"},
  certificate_resolver:.activeRoutingEdge.external.certificateResolver,
  resource_namespace:"inspr-routing-edge",
  upstreams:.activeRoutingEdge.upstreams
}' "$work/projection.json" >"$work/deployment.json"
python3 "$repo_root/doctrine/packages/routing-edge/generate.py" \
  --contract "$work/contract.json" \
  --deployment "$work/deployment.json" \
  --output-dir "$work/rendered"

nix-instantiate --eval --strict --json --expr "
  let f = import ${helper}; in import ${legacy} { privateSourceRanges = f.privateSourceRanges; }
" >"$work/legacy.json"

PATH="$(dirname -- "$(command -v yq)"):$PATH" \
  "$renderer" \
  "$work/merged.yml" \
  "$work/rendered/dynamic.yml" \
  "$work/legacy.json" \
  inspr-routing-edge >/dev/null

if PATH="$(dirname -- "$(command -v yq)"):$PATH" \
  "$renderer" \
  "$work/collision.yml" \
  "$work/rendered/dynamic.yml" \
  "$work/rendered/dynamic.yml" \
  inspr-routing-edge >/dev/null 2>&1; then
  printf '%s\n' 'shared Flow renderer accepted colliding compiler and legacy resources' >&2
  exit 1
fi

for app in aithema paimos pharos janus; do
  jq -e --arg app "$app" '.apps[$app].oidc_redirect_url | startswith("https://flow.inspr.at/" + $app + "/")' \
    "$work/rendered/wiring-report.json" >/dev/null
  yq eval -e ".http.routers.\"inspr-routing-edge-app-${app}\".middlewares[0] == \"cloudflarewarp@file\"" \
    "$work/merged.yml" >/dev/null
done

yq eval -e '
  .http.routers."inspr-legacy-paimos-proxy"
  and .http.routers."inspr-legacy-pharos-private-internal-root"
  and .http.routers."inspr-legacy-janus-private-internal-root"
  and .http.routers."inspr-routing-edge-deny-pharos"
  and .http.routers."inspr-routing-edge-deny-janus"
' "$work/merged.yml" >/dev/null

# One selector gates every new effect. Existing image pins, legacy helper
# semantics, SMTP/env-file wiring, and old host routers remain untouched.
grep -Fq 'sharedFlow = import ./shared-flow.nix;' "$host_config"
grep -Fq 'sharedFlow = import ../shared-flow.nix;' "$compose"
grep -Fq 'enable = sharedFlow.active;' "$host_config"
grep -Fq 'system.activationScripts.sharedFlowRuntimeConfig = lib.mkIf sharedFlow.active' "$host_config"
grep -Fq 'systemd.services.inspr-shared-flow-network = lib.mkIf sharedFlow.active' "$host_config"
grep -Fq 'systemd.services.inspr-shared-flow-config = lib.mkIf sharedFlow.active' "$host_config"

python3 - "$host_config" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
secret_start = source.index("  age.secrets.csb1-aithema-workspace-config =")
secret_end = source.index("\n  };", secret_start)
secret = source[secret_start:secret_end]
for required in (
    "lib.mkIf sharedFlow.active",
    "file = ../../secrets/csb1-aithema-workspace-config.age;",
    "path = sharedFlow.aithema.configFile;",
    'owner = "root";', 'group = "root";', 'mode = "0400";',
    "symlink = false;",
):
    if required not in secret:
        raise SystemExit(f"durable Aithema credential declaration is missing: {required}")
if "restartTriggers = [ config.age.secrets.csb1-aithema-workspace-config.file ];" not in source:
    raise SystemExit("Aithema must refresh its systemd credential after a ciphertext change")
routing_start = source.index("  services.inspr.routingEdge =")
routing_end = source.index("\n\n  # NIX-501 — Aithema", routing_start)
routing = source[routing_start:routing_end]
for required in (
    "services.inspr.routingEdge = lib.recursiveUpdate",
    'certificateResolver = "public-http";',
    "(lib.optionalAttrs sharedFlow.active sharedFlow.routingEdgeActivation)",
):
    if required not in routing:
        raise SystemExit(f"routing-edge active merge is missing: {required}")

triggers_start = source.index("    extraRestartTriggers = [")
triggers_end = source.index("\n    spec = import ./docker/compose-spec.nix;", triggers_start)
triggers = source[triggers_start:triggers_end]
for required in (
    "++ lib.optionals sharedFlow.active [",
    "config.services.inspr.routingEdge.generatedFragmentFile",
    "legacyFlowFragmentFile",
):
    if required not in triggers:
        raise SystemExit(f"active compose restart triggers are missing: {required}")
PY

grep -Fq 'networks = flowNetwork sharedFlow.network.addresses.janus;' "$compose"
grep -Fq 'networks = flowNetwork sharedFlow.network.addresses.paimos;' "$compose"
grep -Fq 'networks = flowNetwork sharedFlow.network.addresses.pharos;' "$compose"
# This checks literal Nix interpolation syntax, not a Bash expansion.
# shellcheck disable=SC2016
grep -Fq 'pharos.barta.cm:${sharedFlow.network.addresses.traefik}' "$compose"
grep -Fq 'privateBind "/run/inspr-shared-flow/dynamic.yml" "/etc/traefik/dynamic/inspr-shared-flow.yml"' "$compose"
grep -Fq 'image = "ghcr.io/inspr-at/paimos:260922104613.0.0@sha256:56f0e529f7fb165d377f8484b5f96adbe4e87c5a1df2e03b4df5ec378e830095"' "$compose"
grep -Fq 'image = "ghcr.io/inspr-at/janus/janus-envelope:go-envelope-v260922094507.0.0@sha256:519888c17e736fdea27e5881d7a1ed10c5f3932fa0d28e0e9368511a2866c639"' "$compose"
grep -Fq 'image = "ghcr.io/inspr-at/pharos/pharosd:260922141211.0.0@sha256:9412708d8debafe0cee662bbd038e4b4894e57e19eafeb8d9661c4e217c81a1a"' "$compose"

printf 'shared_flow_activation=passed active=true runtime_proof_required=true\n'
