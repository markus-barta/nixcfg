#!/usr/bin/env bash
# T78 — consume the published Aithema 0.7 NixOS module on csb1 while keeping
# production runtime custody, IAM, routing and activation explicitly absent.
set -euo pipefail

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'Aithema workspace consumer test failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
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
consumer_eval="$repo_root/tests/aithema-workspace-consumer-eval.nix"
expected_rev="477ae3f2169ca1aefbaf16e03eea1a2ed6c1cc8b"
expected_narhash="sha256-XEEj4nfTdlcYPrPGv3m8dyisjwFiDASrGaFeSNatdAY="
expected_version="0.7.0"
expected_source_rev="981e4d49b9360c430ae944afa4df29a37d536c76"
repo_revision=$(git -C "$repo_root" rev-parse HEAD)
export NIX498_FLAKE_REF="git+file://${repo_root}?rev=${repo_revision}&shallow=1"

for file in "$flake_nix" "$flake_lock" "$host_config" "$consumer_eval"; do
  [ -f "$file" ]
done
for file in "$flake_nix" "$host_config" "$consumer_eval"; do
  nix-instantiate --parse "$file" >/dev/null
done

# The host consumes the one already-reviewed immutable input; no new fetch or
# copy of the public module is allowed in this consumer slice.
jq -e --arg rev "$expected_rev" --arg nar "$expected_narhash" '
  .nodes["inspr-modules"].original.rev == $rev
  and .nodes["inspr-modules"].locked.rev == $rev
  and .nodes["inspr-modules"].locked.narHash == $nar
' "$flake_lock" >/dev/null
grep -Fq "inspr-modules.url = \"github:inspr-at/inspr-modules/$expected_rev\"" "$flake_nix"
grep -Fq 'inputs.inspr-modules.nixosModules.aithema-workspace' "$host_config"
grep -Fq 'package = inputs.inspr-modules.packages.x86_64-linux.aithema-workspace;' "$host_config"
grep -Fq 'services.inspr.aithemaWorkspace = {' "$host_config"
grep -Fq '    enable = false;' "$host_config"
grep -Fq '    stateDirectory = "aithema-workspace";' "$host_config"
grep -Fq '    configFile = null;' "$host_config"

projection=$(nix eval --impure --json --file "$consumer_eval")
jq -e \
  --arg version "$expected_version" \
  --arg source_rev "$expected_source_rev" '
  .disabled == {
    enable: false,
    configFile: null,
    stateDirectory: "aithema-workspace",
    packageName: "aithema-workspace",
    packageVersion: $version,
    packageSourceRevision: $source_rev,
    hasService: false,
    hasUser: false,
    hasGroup: false,
    hasStateDirectoryEffect: false,
    hasCredentialEffect: false
  }
  and .enabled.assertionFailures == []
  and .enabled.user == {
    isSystemUser: true,
    group: "aithema",
    home: "/var/lib/aithema-workspace"
  }
  and .enabled.hasGroup == true
  and .enabled.service.user == "aithema"
  and .enabled.service.group == "aithema"
  and .enabled.service.dynamicUser == false
  and .enabled.service.stateDirectory == "aithema-workspace"
  and .enabled.service.stateDirectoryMode == "0750"
  and .enabled.service.workingDirectory == "/var/lib/aithema-workspace"
  and .enabled.service.readWritePaths == ["/var/lib/aithema-workspace"]
  and .enabled.service.loadCredential == "runtime-config.json:/run/nix498-fixture/aithema-workspace.json"
  and (.enabled.service.execStart | contains("/run/credentials/aithema-workspace.service/runtime-config.json"))
  and (.enabled.service.execStart | contains("/run/nix498-fixture/aithema-workspace.json") | not)
  and (.enabled.service.execStartPre | contains("/run/credentials/aithema-workspace.service/runtime-config.json"))
  and (.enabled.service.execStartPre | contains("/var/lib/aithema-workspace"))
  and (.enabled.service.execStartPre | contains("/run/nix498-fixture/aithema-workspace.json") | not)
  and .enabled.service.noNewPrivileges == true
  and .enabled.service.protectHome == true
  and .enabled.service.protectSystem == "strict"
  and any(.rejected.missingConfig[]; contains("configFile is required"))
  and any(.rejected.storeConfig[]; contains("outside the Nix store"))
' <<<"$projection" >/dev/null

printf 'aithema_workspace_consumer=passed\n'
