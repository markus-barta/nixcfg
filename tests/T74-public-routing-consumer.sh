#!/usr/bin/env bash
# T74 — pin the published routing-edge library and keep the csb1 consumer
# boundary inactive (NIX-447). NIX-501 prepares the activation contract behind
# the shared Flow selector; the actual projection below must remain effect-free.
#
# What can actually go wrong here, and what each block therefore proves:
#
#   1. Flake input and doctrine gitlink drift apart, so hosts run a library
#      sessions have not read (or the reverse). T42 still owns the checker
#      blob; this test owns the synchronized immutable source coordinate.
#      NIX-501 consumes release0.12.0 / Aithema0.8.0; routing implementation
#      and checker blob stay byte-identical to the previous pin.
#   2. A copied stub eval can stay disabled while the real host is not.
#      Disabled effects are projected from nixosConfigurations.csb1.
#   3. Prepared selectors accidentally install a routing-owned fragment,
#      service, or compose mount, or the host Traefik image floats again.
#   4. The prepared activation contract leaks into the inactive evaluated
#      module state.
#   5. Forcing enable=true without flipping the shared selector must fail
#      closed, not silently compile a fragment from an inactive contract.
set -euo pipefail

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'public routing consumer test failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case "$repo_root" in
*" "* | *"#"* | *"?"*)
  printf 'repository path is not safe for a local Git flake URL\n' >&2
  exit 1
  ;;
esac

flake_nix="$repo_root/flake.nix"
flake_lock="$repo_root/flake.lock"
host_config="$repo_root/hosts/csb1/configuration.nix"
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
t42="$repo_root/tests/T42-doctrine-paths-agree.sh"
consumer_eval="$repo_root/tests/routing-edge-consumer-eval.nix"
expected_rev="c784570daa3bc87ae115f1628c18c110609a14a0"
expected_narhash="sha256-oiQHaMcP8cjYvEzMu4hTUryVogvxumkOzJ+7SBdmwPs="
expected_checker_blob="ef37a597e3100fb1704be5708a2c32cedd4ac7d5"
provider_file="traefik/dynamic/inspr-routing-edge.yml"
repo_revision="$(git -C "$repo_root" rev-parse HEAD)"
export NIX447_FLAKE_REF="git+file://${repo_root}?rev=${repo_revision}&shallow=1"

for file in "$flake_nix" "$flake_lock" "$host_config" "$compose" "$t42" "$consumer_eval"; do
  [ -f "$file" ]
done
nix-instantiate --parse "$flake_nix" >/dev/null
nix-instantiate --parse "$host_config" >/dev/null
nix-instantiate --parse "$compose" >/dev/null
nix-instantiate --parse "$consumer_eval" >/dev/null

# --- 1. synchronized public pin; T42 checker provenance unchanged ----------
jq -e --arg rev "$expected_rev" --arg nar "$expected_narhash" '
  .nodes["inspr-modules"].original.rev == $rev
  and .nodes["inspr-modules"].locked.rev == $rev
  and .nodes["inspr-modules"].locked.narHash == $nar
  and .nodes["inspr-modules"].locked.owner == "inspr-at"
  and .nodes["inspr-modules"].locked.repo == "inspr-modules"
' "$flake_lock" >/dev/null

grep -Fq "inspr-modules.url = \"github:inspr-at/inspr-modules/$expected_rev\"" "$flake_nix"
if grep -E '^[[:space:]]+.*\.url = ".*routing' "$flake_nix" | grep -vq 'inspr-modules'; then
  printf 'T74: found a new routing flake input; consume inspr-modules only\n' >&2
  exit 1
fi

gitlink_entry="$(git -C "$repo_root" ls-files --stage -- doctrine)"
read -r gitlink_mode doctrine_rev _gitlink_stage gitlink_path <<EOF
$gitlink_entry
EOF
[ "$gitlink_mode" = "160000" ]
[ "$gitlink_path" = "doctrine" ]
[ "$doctrine_rev" = "$expected_rev" ]

grep -Fq "expected_checker_blob=\"$expected_checker_blob\"" "$t42"

# --- 2. actual host source binds the published module and linux package ----
grep -Fq 'inputs.inspr-modules.nixosModules.routing-edge' "$host_config"
grep -Fq 'package = inputs.inspr-modules.packages.x86_64-linux.routing-edge' "$host_config"

# --- 3. existing Traefik auth fragment stays distinct in source ------------
grep -Fq 'directory: /etc/traefik/dynamic' "$repo_root/hosts/csb1/docker/traefik/static.yml"
grep -Fq 'web-secure:' "$repo_root/hosts/csb1/docker/traefik/static.yml"
if grep -Fq 'image = "traefik";' "$compose"; then
  printf 'T74: csb1 Traefik image is still the unpinned floating tag\n' >&2
  exit 1
fi
grep -Fq 'image = "traefik:v3.7.13@sha256:f86a2cab1b5c649070c49f883c743dd32d8485a56e3368c5f93b9e91f1e91259"' "$compose"
grep -Fq '(privateBind "/run/inspr-edge/dynamic.yml" "/etc/traefik/dynamic/inspr-edge.yml")' "$compose"
if grep -Eq 'inspr-auth-edge-token' "$compose"; then
  :
else
  printf 'T74: existing inspr-auth edge fragment wiring disappeared\n' >&2
  exit 1
fi

# --- 4. actual csb1 projection: disabled, no routing-owned effects ---------
eval_json="$(nix eval --impure --json --file "$consumer_eval")"
jq -e --arg provider "$provider_file" '
  .enable == false
  and .deploymentMode == "external-file-provider"
  and .entrypointName == "web-secure"
  and .certificateResolver == "public-http"
  and .resourceNamespace == "inspr-routing-edge"
  and .providerFile == $provider
  and .allowUnpinnedTraefik == false
  and .existingTraefikVersion == null
  and .upstreamIds == []
  and .packageSystem == "x86_64-linux"
  and (.packageName == "inspr-routing-edge" or .packageName == "routing-edge")
  and .hasRoutingEdgeService == false
  and .routingEtcNames == []
  and .composeMentionsOwnedFragment == false
  and .generatedFragmentFile == null
  and .generatedDeployment == {}
  and .routingFailedAssertionCount == 0
  and .routingWarningCount == 0
  and .enableTrueMissingContractFailed == true
' <<<"$eval_json" >/dev/null

printf 'public_routing_consumer=passed\n'
