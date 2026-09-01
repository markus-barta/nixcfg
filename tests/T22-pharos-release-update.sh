#!/usr/bin/env bash
set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
# OPS-127: the specs are the release-pin source of truth (ymls retired)
compose_files=(
  hosts/csb0/docker/compose-spec.nix
  hosts/csb1/docker/compose-spec.nix
  hosts/hsb0/docker/compose-spec.nix
  hosts/hsb1/docker/compose-spec.nix
  hosts/hsb8/docker/compose-spec.nix
  hosts/hsb9/docker/compose-spec.nix
)
readiness=hosts/csb1/docker/janus/managed-service-production/readiness.sh
provisioning_module=modules/pharos-provisioning-executor/default.nix

cleanup() {
  find "$fixture" -type f -delete
  find "$fixture" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

cp "$repo_root/pharos-release.json" "$fixture/pharos-release.json"
for relative in "${compose_files[@]}"; do
  mkdir -p "$fixture/$(dirname "$relative")"
  cp "$repo_root/$relative" "$fixture/$relative"
done
mkdir -p "$fixture/$(dirname "$readiness")"
cp "$repo_root/$readiness" "$fixture/$readiness"
mkdir -p "$fixture/$(dirname "$provisioning_module")"
cp "$repo_root/$provisioning_module" "$fixture/$provisioning_module"

new_digest="sha256:$(printf 'b%.0s' {1..64})"
active_scheme=$(jq -r .version_scheme "$fixture/pharos-release.json")
active_sequence=$(jq -r .release_sequence "$fixture/pharos-release.json")
if [[ "$active_scheme" == legacy ]]; then
  stored_first=$(jq -r .migration_anchor.first_calendar_version "$fixture/pharos-release.json")
  if [[ "$stored_first" == null ]]; then
    new_version=26.09.02.03.04.05
  else
    new_version=$stored_first
  fi
  new_sequence=1
  first_version=$new_version
else
  new_version=$(
    python3 - "$(jq -r .version "$fixture/pharos-release.json")" <<'PY'
import datetime as dt
import sys

fields = [int(part) for part in sys.argv[1].split(".")]
current = dt.datetime(2000 + fields[0], *fields[1:]) + dt.timedelta(seconds=1)
print(f"{current.year % 100:02d}.{current:%m.%d.%H.%M.%S}")
PY
  )
  new_sequence=$((active_sequence + 1))
  first_version=$(jq -r .migration_anchor.first_calendar_version "$fixture/pharos-release.json")
fi
expected="ghcr.io/inspr-at/pharos/pharosd:${new_version}@${new_digest}"
IFS=. read -r new_year new_month new_day new_hour new_minute new_second <<<"$new_version"
cargo_version="$((2000 + 10#$new_year)).$((10#$new_month * 100 + 10#$new_day)).$((10#$new_hour * 10000 + 10#$new_minute * 100 + 10#$new_second))"
release_set="$fixture/release-set.json"
jq -n \
  --arg version "$new_version" \
  --arg cargo_version "$cargo_version" \
  --arg first_version "$first_version" \
  --argjson sequence "$new_sequence" \
  --arg digest "$new_digest" \
  --arg reference "$expected" \
  '{
    schema: "inspr.pharos.release-set.v1",
    schema_version: 1,
    version_scheme: "inspr-calendar-v1",
    version: $version,
    release_channel: "stable",
    release_sequence: $sequence,
    migration_anchor: {
      last_legacy_version: "0.2.0",
      last_legacy_release_sequence: 0,
      first_calendar_version: $first_version,
      first_calendar_release_sequence: 1
    },
    cargo_version: $cargo_version,
    source_commit: ("c" * 40),
    source_lock_digest: ("sha256:" + ("d" * 64)),
    sha_reference: ("ghcr.io/inspr-at/pharos/pharosd:sha-" + ("c" * 40) + "@" + $digest),
    tag: ("v" + $version),
    image: "ghcr.io/inspr-at/pharos/pharosd",
    digest: $digest,
    reference: $reference,
    artifacts: [
      {
        coordinate: {
          class: "oci-index",
          version_reference: $reference,
          source_reference: ("ghcr.io/inspr-at/pharos/pharosd:sha-" + ("c" * 40) + "@" + $digest)
        },
        digest: $digest
      },
      {coordinate: {class: "oci-image", platform: "linux/amd64"}, digest: ("sha256:" + ("e" * 64))},
      {coordinate: {class: "spdx-sbom", filename: "pharos.spdx.json"}, digest: ("sha256:" + ("f" * 64))}
    ],
    attestations: {
      signature: {
        coordinate: ("ghcr.io/inspr-at/pharos/pharosd:sha256-" + ($digest | sub("^sha256:"; "")) + ".sig@sha256:" + ("1" * 64)),
        digest: ("sha256:" + ("1" * 64))
      },
      provenance: {
        coordinate: ("ghcr.io/inspr-at/pharos/pharosd@sha256:" + ("2" * 64)),
        manifest_digest: ("sha256:" + ("2" * 64)),
        layer_digest: ("sha256:" + ("3" * 64)),
          predicate_type: "https://slsa.dev/provenance/v1"
      },
      sbom: {
        coordinate: ("ghcr.io/inspr-at/pharos/pharosd@sha256:" + ("2" * 64)),
        manifest_digest: ("sha256:" + ("2" * 64)),
        layer_digest: ("sha256:" + ("4" * 64)),
        predicate_type: "https://spdx.dev/Document"
      }
    },
    legacy_rollback: {
      version_scheme: "legacy",
      version: "0.2.0",
      release_channel: "stable",
      release_sequence: 0,
      source_commit: "5c8bd1fbd2271a5c157ca239ec2d98b66b201e19",
      tag: "v0.2.0",
      image: "ghcr.io/inspr-at/pharos/pharosd",
      digest: "sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b",
      reference: "ghcr.io/inspr-at/pharos/pharosd:0.2.0@sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b"
    }
  }' >"$release_set"

"$repo_root/scripts/update-pharos-release.sh" --root "$fixture" "$release_set" >/dev/null
[[ "$(jq -r '.reference' "$fixture/pharos-release.json")" == "$expected" ]]
[[ "$(jq -r '.version_scheme' "$fixture/pharos-release.json")" == inspr-calendar-v1 ]]
[[ "$(jq -r '.release_sequence' "$fixture/pharos-release.json")" == "$new_sequence" ]]
[[ "$(grep -rlF "image = \"$expected\";" "$fixture/hosts" | wc -l | tr -d ' ')" == 6 ]]
[[ "$(grep -rF "image = \"$expected\";" "$fixture/hosts" | wc -l | tr -d ' ')" == 7 ]]
escaped_version=${new_version//./\\.}
grep -Fq \
  "'^ghcr\\.io/inspr-at/pharos/pharosd:${escaped_version}@sha256:[0-9a-f]{64}$'" \
  "$fixture/$readiness"

bootstrap_default=$(
  FIXTURE_ROOT="$fixture" nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString ./.);
      fixture = builtins.getEnv "FIXTURE_ROOT";
      pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
      modulePath = builtins.toPath (fixture + "/modules/pharos-provisioning-executor/default.nix");
      module = import modulePath {
        config = {
          networking.hostName = "fixture";
          inspr.pharosProvisioningExecutor = { };
        };
        inputs = flake.inputs;
        lib = flake.inputs.nixpkgs.lib;
        inherit pkgs;
      };
    in
    module.options.inspr.pharosProvisioningExecutor.beaconImage.default
  '
)
[[ "$bootstrap_default" == "$expected" ]]

before=$(find "$fixture" -type f -print | LC_ALL=C sort | xargs sha256sum)
"$repo_root/scripts/update-pharos-release.sh" --root "$fixture" "$release_set" >/dev/null
after=$(find "$fixture" -type f -print | LC_ALL=C sort | xargs sha256sum)
[[ "$before" == "$after" ]]

rollback_target="$fixture/rollback-target.json"
python3 "$repo_root/scripts/pharos-release-metadata.py" rollback \
  --active "$fixture/pharos-release.json" \
  --tag v0.2.0 \
  --output "$rollback_target"
if "$repo_root/scripts/update-pharos-release.sh" \
  --root "$fixture" \
  "$rollback_target" >/dev/null 2>&1; then
  printf 'pharos_release_update_test=failed reason=unattended_rollback_accepted\n' >&2
  exit 1
fi
"$repo_root/scripts/update-pharos-release.sh" \
  --root "$fixture" \
  --allow-exact-rollback v0.2.0 \
  "$rollback_target" >/dev/null
[[ "$(jq -r .version_scheme "$fixture/pharos-release.json")" == legacy ]]
[[ "$(jq -r .digest "$fixture/pharos-release.json")" == sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b ]]
[[ "$(jq -r .migration_anchor.first_calendar_version "$fixture/pharos-release.json")" == "$first_version" ]]
rollback_reference=$(jq -r .reference "$fixture/pharos-release.json")
[[ "$(grep -rF "image = \"$rollback_reference\";" "$fixture/hosts" | wc -l | tr -d ' ')" == 7 ]]

short_release="$fixture/short-release.json"
jq '
  .version = "26.09.02"
  | .migration_anchor.first_calendar_version = .version
  | .tag = ("v" + .version)
  | .reference = (.image + ":" + .version + "@" + .digest)
' "$release_set" >"$short_release"
if "$repo_root/scripts/update-pharos-release.sh" --root "$fixture" "$short_release" >/dev/null 2>&1; then
  printf 'pharos_release_update_test=failed reason=short_calendar_version_accepted\n' >&2
  exit 1
fi
bad_digest="$fixture/bad-digest.json"
jq '
  .digest = "sha256:short"
  | .reference = (.image + ":" + .version + "@" + .digest)
  | .artifacts[0].digest = .digest
  | .attestations.provenance = (.image + "@" + .digest + "#slsa")
  | .attestations.sbom = (.image + "@" + .digest + "#spdx")
' \
  "$release_set" >"$bad_digest"
if "$repo_root/scripts/update-pharos-release.sh" --root "$fixture" "$bad_digest" >/dev/null 2>&1; then
  printf 'pharos_release_update_test=failed reason=invalid_digest_accepted\n' >&2
  exit 1
fi

printf 'pharos_release_update_test=passed\n'
