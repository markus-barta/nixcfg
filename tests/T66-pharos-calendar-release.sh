#!/usr/bin/env bash
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
validator="$repo_root/scripts/pharos-release-metadata.py"
fixture=$(mktemp -d)

cleanup() {
  find "$fixture" -type f -delete
  find "$fixture" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

make_calendar() {
  local version=$1
  local sequence=$2
  local first=$3
  local output=$4
  local digest
  local cargo_version
  digest="sha256:$(printf '%064x' "$sequence")"
  IFS=. read -r year month day hour minute second <<<"$version"
  cargo_version="$((2000 + 10#$year)).$((10#$month * 100 + 10#$day)).$((10#$hour * 10000 + 10#$minute * 100 + 10#$second))"
  jq -n \
    --arg version "$version" \
    --arg cargo_version "$cargo_version" \
    --argjson sequence "$sequence" \
    --arg first "$first" \
    --arg digest "$digest" \
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
        first_calendar_version: $first,
        first_calendar_release_sequence: 1
      },
      cargo_version: $cargo_version,
      source_commit: ("c" * 40),
      source_lock_digest: ("sha256:" + ("d" * 64)),
      sha_reference: ("ghcr.io/inspr-at/pharos/pharosd:sha-" + ("c" * 40) + "@" + $digest),
      tag: ("v" + $version),
      image: "ghcr.io/inspr-at/pharos/pharosd",
      digest: $digest,
      reference: ("ghcr.io/inspr-at/pharos/pharosd:" + $version + "@" + $digest),
      artifacts: [
        {
          coordinate: {
            class: "oci-index",
            version_reference: ("ghcr.io/inspr-at/pharos/pharosd:" + $version + "@" + $digest),
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
    }' >"$output"
}

# PHAROS-259: calendar v2 release-set (YYMMDDhhmmss.0.0, identity Cargo mapping,
# two-step migration anchor). Arguments: version sequence first_v1 last_v1
# last_v1_sequence first_v2 output.
make_calendar_v2() {
  local version=$1
  local sequence=$2
  local first_v1=$3
  local last_v1=$4
  local last_v1_sequence=$5
  local first_v2=$6
  local output=$7
  local digest
  digest="sha256:$(printf '%064x' "$sequence")"
  jq -n \
    --arg version "$version" \
    --argjson sequence "$sequence" \
    --arg first_v1 "$first_v1" \
    --arg last_v1 "$last_v1" \
    --argjson last_v1_sequence "$last_v1_sequence" \
    --arg first_v2 "$first_v2" \
    --arg digest "$digest" \
    '{
      schema: "inspr.pharos.release-set.v1",
      schema_version: 1,
      version_scheme: "inspr-calendar-v2",
      version: $version,
      release_channel: "stable",
      release_sequence: $sequence,
      migration_anchor: {
        last_legacy_version: "0.2.0",
        last_legacy_release_sequence: 0,
        first_calendar_version: $first_v1,
        first_calendar_release_sequence: 1,
        last_calendar_v1_version: $last_v1,
        last_calendar_v1_release_sequence: $last_v1_sequence,
        first_calendar_v2_version: $first_v2,
        first_calendar_v2_release_sequence: ($last_v1_sequence + 1)
      },
      cargo_version: $version,
      source_commit: ("c" * 40),
      source_lock_digest: ("sha256:" + ("d" * 64)),
      sha_reference: ("ghcr.io/inspr-at/pharos/pharosd:sha-" + ("c" * 40) + "@" + $digest),
      tag: ("v" + $version),
      image: "ghcr.io/inspr-at/pharos/pharosd",
      digest: $digest,
      reference: ("ghcr.io/inspr-at/pharos/pharosd:" + $version + "@" + $digest),
      artifacts: [
        {
          coordinate: {
            class: "oci-index",
            version_reference: ("ghcr.io/inspr-at/pharos/pharosd:" + $version + "@" + $digest),
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
    }' >"$output"
}

assert_rejected() {
  local candidate=$1
  if python3 "$validator" validate --kind release-set "$candidate" >/dev/null 2>&1; then
    printf 'pharos_calendar_release_test=failed reason=invalid_candidate_accepted path=%s\n' \
      "${candidate##*/}" >&2
    exit 1
  fi
}

python3 "$validator" validate --kind local "$repo_root/pharos-release.json"
active="$fixture/legacy-local.json"
jq -n '{
  schema: "inspr.pharos.fleet-release.v2",
  version_scheme: "legacy",
  version: "0.2.0",
  release_channel: "stable",
  release_sequence: 0,
  migration_anchor: {
    last_legacy_version: "0.2.0",
    last_legacy_release_sequence: 0,
    first_calendar_version: null,
    first_calendar_release_sequence: 1
  },
  source_commit: "5c8bd1fbd2271a5c157ca239ec2d98b66b201e19",
  tag: "v0.2.0",
  image: "ghcr.io/inspr-at/pharos/pharosd",
  digest: "sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b",
  reference: "ghcr.io/inspr-at/pharos/pharosd:0.2.0@sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b",
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
}' >"$active"
python3 "$validator" validate --kind local "$active"
wrong_legacy_root="$fixture/wrong-legacy-root.json"
jq '
  .digest = ("sha256:" + ("0" * 64))
  | .reference = (.image + ":" + .version + "@" + .digest)
' "$active" >"$wrong_legacy_root"
if python3 "$validator" validate --kind local "$wrong_legacy_root" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=mismatched_legacy_root_accepted\n' >&2
  exit 1
fi

first_version=26.09.02.03.04.05
first="$fixture/first.json"
later="$fixture/later.json"
make_calendar "$first_version" 1 "$first_version" "$first"
make_calendar 26.09.02.04.00.00 2 "$first_version" "$later"
python3 "$validator" validate --kind release-set "$first"
python3 "$validator" validate --kind release-set "$later"

selected="$fixture/selected.json"
python3 "$validator" select \
  --active "$active" \
  --output "$selected" \
  "$first" \
  "$later"
[[ "$(jq -r .release_sequence "$selected")" == 2 ]]
[[ "$(jq -r .version "$selected")" == 26.09.02.04.00.00 ]]

first_local="$fixture/first-local.json"
python3 "$validator" transition --active "$active" --candidate "$first" --output "$first_local"
[[ "$(jq -r .schema "$first_local")" == inspr.pharos.fleet-release.v2 ]]
jq -e '
  (has("schema_version") | not)
  and (has("cargo_version") | not)
  and (has("source_lock_digest") | not)
  and (has("sha_reference") | not)
  and (has("artifacts") | not)
  and (has("attestations") | not)
  and has("legacy_rollback")
' "$first_local" >/dev/null
python3 "$validator" select --active "$first_local" --output "$selected" "$later"
[[ "$(jq -r .release_sequence "$selected")" == 2 ]]
later_local="$fixture/later-local.json"
python3 "$validator" transition --active "$first_local" --candidate "$later" --output "$later_local"
historical_order_mismatch="$fixture/historical-order-mismatch.json"
make_calendar 26.09.02.05.00.00 1 "$first_version" "$historical_order_mismatch"
if python3 "$validator" select \
  --active "$later_local" \
  --output "$selected" \
  "$historical_order_mismatch" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=historical_order_mismatch_accepted\n' >&2
  exit 1
fi
python3 "$validator" select \
  --active "$later_local" \
  --output "$selected" \
  "$first" \
  "$later"
[[ "$(jq -r .release_sequence "$selected")" == 2 ]]

short="$fixture/short.json"
jq '
  .version = "26.09.02"
  | .migration_anchor.first_calendar_version = .version
  | .tag = ("v" + .version)
  | .reference = (.image + ":" + .version + "@" + .digest)
' "$first" >"$short"
assert_rejected "$short"

invalid_date="$fixture/invalid-date.json"
jq '
  .version = "26.02.29.03.04.05"
  | .migration_anchor.first_calendar_version = .version
  | .tag = ("v" + .version)
  | .reference = (.image + ":" + .version + "@" + .digest)
' "$first" >"$invalid_date"
assert_rejected "$invalid_date"

invalid_time="$fixture/invalid-time.json"
jq '
  .version = "26.09.02.24.00.00"
  | .migration_anchor.first_calendar_version = .version
  | .tag = ("v" + .version)
  | .reference = (.image + ":" + .version + "@" + .digest)
' "$first" >"$invalid_time"
assert_rejected "$invalid_time"

unknown_scheme="$fixture/unknown-scheme.json"
jq '.version_scheme = "calendar"' "$first" >"$unknown_scheme"
assert_rejected "$unknown_scheme"

missing_scheme="$fixture/missing-scheme.json"
jq 'del(.version_scheme)' "$first" >"$missing_scheme"
assert_rejected "$missing_scheme"

post_anchor_legacy="$fixture/post-anchor-legacy.json"
jq '
  .version_scheme = "legacy"
  | .version = "0.2.1"
  | .release_sequence = 1
  | .migration_anchor.first_calendar_version = null
  | .tag = "v0.2.1"
  | .reference = (.image + ":0.2.1@" + .digest)
' "$first" >"$post_anchor_legacy"
assert_rejected "$post_anchor_legacy"

wrong_first="$fixture/wrong-first.json"
jq '.migration_anchor.first_calendar_version = "26.09.02.03.04.06"' "$first" >"$wrong_first"
assert_rejected "$wrong_first"

wrong_schema_version="$fixture/wrong-schema-version.json"
jq '.schema_version = 2' "$first" >"$wrong_schema_version"
assert_rejected "$wrong_schema_version"

wrong_cargo="$fixture/wrong-cargo.json"
jq '.cargo_version = "2026.902.030406"' "$first" >"$wrong_cargo"
assert_rejected "$wrong_cargo"

wrong_sha_reference="$fixture/wrong-sha-reference.json"
jq '.sha_reference = .reference' "$first" >"$wrong_sha_reference"
assert_rejected "$wrong_sha_reference"

wrong_source_coordinate="$fixture/wrong-source-coordinate.json"
jq '.artifacts[0].coordinate.source_reference = .reference' \
  "$first" >"$wrong_source_coordinate"
assert_rejected "$wrong_source_coordinate"

wrong_platform="$fixture/wrong-platform.json"
jq '.artifacts[1].coordinate.platform = "linux/arm64"' "$first" >"$wrong_platform"
assert_rejected "$wrong_platform"

wrong_attestation="$fixture/wrong-attestation.json"
jq '.attestations.provenance = (.image + "@" + .digest + "#other")' \
  "$first" >"$wrong_attestation"
assert_rejected "$wrong_attestation"

wrong_signature="$fixture/wrong-signature.json"
jq '.attestations.signature.coordinate = (.image + "@" + .attestations.signature.digest)' \
  "$first" >"$wrong_signature"
assert_rejected "$wrong_signature"

split_manifests="$fixture/split-manifests.json"
jq '
  .attestations.sbom.manifest_digest = ("sha256:" + ("5" * 64))
  | .attestations.sbom.coordinate = (.image + "@" + .attestations.sbom.manifest_digest)
' "$first" >"$split_manifests"
assert_rejected "$split_manifests"

wrong_rollback="$fixture/wrong-rollback.json"
jq '.legacy_rollback.digest = ("sha256:" + ("0" * 64))' "$first" >"$wrong_rollback"
assert_rejected "$wrong_rollback"

collision="$fixture/collision.json"
make_calendar 26.09.02.05.00.00 2 "$first_version" "$collision"
if python3 "$validator" select \
  --active "$active" \
  --output "$selected" \
  "$later" \
  "$collision" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=sequence_collision_accepted\n' >&2
  exit 1
fi

reverse_sequence="$fixture/reverse-sequence.json"
make_calendar 26.09.02.03.30.00 3 "$first_version" "$reverse_sequence"
if python3 "$validator" select \
  --active "$active" \
  --output "$selected" \
  "$later" \
  "$reverse_sequence" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=calendar_sequence_order_mismatch_accepted\n' >&2
  exit 1
fi

if python3 "$validator" select \
  --active "$later_local" \
  --output "$selected" \
  "$first" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=normal_legacy_downgrade_accepted\n' >&2
  exit 1
fi
if python3 "$validator" rollback \
  --active "$later_local" \
  --tag v0.2.1 \
  --output "$selected" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=inexact_rollback_tag_accepted\n' >&2
  exit 1
fi
python3 "$validator" rollback \
  --active "$later_local" \
  --tag v0.2.0 \
  --output "$selected"
[[ "$(jq -r .tag "$selected")" == v0.2.0 ]]
[[ "$(jq -r .digest "$selected")" == sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b ]]
[[ "$(jq -r .migration_anchor.first_calendar_version "$selected")" == "$first_version" ]]
alternate_anchor="$fixture/alternate-anchor.json"
make_calendar 26.09.03.03.04.05 1 26.09.03.03.04.05 "$alternate_anchor"
if python3 "$validator" transition \
  --active "$selected" \
  --candidate "$alternate_anchor" \
  --output "$first_local" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=rollback_anchor_relearned\n' >&2
  exit 1
fi

if rg -n 'sort -V|type=semver' \
  "$repo_root/.github/workflows/pharos-release-rollout.yml" \
  "$repo_root/scripts/update-pharos-release.sh" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" \
  "$repo_root/scripts/select-pharos-release-candidates.sh" \
  "$repo_root/scripts/publish-pharos-release-candidates.sh"; then
  printf 'pharos_calendar_release_test=failed reason=generic_version_inference_present\n' >&2
  exit 1
fi

# ── calendar v1 → v2 transition (PHAROS-259) ────────────────────────────────
later_local="$fixture/later-local.json"
python3 "$validator" transition --active "$active" --candidate "$later" --output "$later_local"
[[ "$(jq -r .version_scheme "$later_local")" == inspr-calendar-v1 ]]
v2_first_version=260903050607.0.0
v2_first="$fixture/v2-first.json"
make_calendar_v2 "$v2_first_version" 3 "$first_version" 26.09.02.04.00.00 2 "$v2_first_version" "$v2_first"
python3 "$validator" validate --kind release-set "$v2_first"
v2_local="$fixture/v2-local.json"
python3 "$validator" transition --active "$later_local" --candidate "$v2_first" --output "$v2_local"
[[ "$(jq -r .version_scheme "$v2_local")" == inspr-calendar-v2 ]]
[[ "$(jq -r .version "$v2_local")" == "$v2_first_version" ]]
[[ "$(jq -r .migration_anchor.last_calendar_v1_version "$v2_local")" == 26.09.02.04.00.00 ]]
[[ "$(jq -r .migration_anchor.first_calendar_v2_release_sequence "$v2_local")" == 3 ]]
python3 "$validator" validate --kind local "$v2_local"

# A later v2 coordinate follows within the era; string order equals time order.
v2_later="$fixture/v2-later.json"
make_calendar_v2 260903050608.0.0 4 "$first_version" 26.09.02.04.00.00 2 "$v2_first_version" "$v2_later"
v2_later_local="$fixture/v2-later-local.json"
python3 "$validator" transition --active "$v2_local" --candidate "$v2_later" --output "$v2_later_local"
[[ "$(jq -r .release_sequence "$v2_later_local")" == 4 ]]
selected_v2="$fixture/selected-v2.json"
python3 "$validator" select --active "$v2_local" --output "$selected_v2" "$v2_first" "$v2_later"
[[ "$(jq -r .version "$selected_v2")" == 260903050608.0.0 ]]

# A first v2 reservation that never published may be skipped: sequence 4 lands
# directly on the v1 record while the anchor still names the sequence-3 coordinate.
skipped_local="$fixture/v2-skipped-local.json"
python3 "$validator" transition --active "$later_local" --candidate "$v2_later" --output "$skipped_local"
[[ "$(jq -r .release_sequence "$skipped_local")" == 4 ]]
[[ "$(jq -r .migration_anchor.first_calendar_v2_version "$skipped_local")" == "$v2_first_version" ]]
make_calendar_v2 260903050609.0.0 5 "$first_version" 26.09.02.04.00.00 2 260903050609.0.0 "$fixture/v2-relearned.json"
if python3 "$validator" transition --active "$later_local" --candidate "$fixture/v2-relearned.json" --output "$fixture/never.json" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=v2_first_reservation_relearned\n' >&2
  exit 1
fi

# Rejections: v1 after v2 is closed; wrong v1→v2 anchor; v1 spelling under v2;
# non-zero PATCH; earlier v2 coordinate; identity Cargo mapping broken.
v1_after_v2="$fixture/v1-after-v2.json"
make_calendar 26.09.03.06.00.00 5 "$first_version" "$v1_after_v2"
if python3 "$validator" transition --active "$v2_local" --candidate "$v1_after_v2" --output "$fixture/never.json" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=v1_accepted_after_v2\n' >&2
  exit 1
fi
wrong_anchor="$fixture/v2-wrong-anchor.json"
make_calendar_v2 "$v2_first_version" 3 "$first_version" "$first_version" 1 "$v2_first_version" "$wrong_anchor"
if python3 "$validator" transition --active "$later_local" --candidate "$wrong_anchor" --output "$fixture/never.json" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=v2_anchor_mismatch_accepted\n' >&2
  exit 1
fi
for bad in 26.09.03.05.06.07 260903050607.0.1 2609030506.0.0 260903050607.0.0-rc1 260230050607.0.0; do
  make_calendar_v2 "$bad" 3 "$first_version" 26.09.02.04.00.00 2 "$bad" "$fixture/v2-bad.json"
  assert_rejected "$fixture/v2-bad.json"
done
make_calendar_v2 260903050606.0.0 4 "$first_version" 26.09.02.04.00.00 2 "$v2_first_version" "$fixture/v2-earlier.json"
if python3 "$validator" transition --active "$v2_local" --candidate "$fixture/v2-earlier.json" --output "$fixture/never.json" >/dev/null 2>&1; then
  printf 'pharos_calendar_release_test=failed reason=earlier_v2_coordinate_accepted\n' >&2
  exit 1
fi
jq '.cargo_version = "2026.903.50607"' "$v2_first" >"$fixture/v2-cargo.json"
assert_rejected "$fixture/v2-cargo.json"
printf 'pharos_calendar_release_test=passed\n'
