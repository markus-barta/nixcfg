#!/usr/bin/env bash
set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${repo}" =~ [[:space:]#?] ]]; then
  printf 'repository path is not safe for a local Git flake URL\n' >&2
  exit 1
fi
repo_revision="$(git -C "${repo}" rev-parse HEAD)"
flake_ref="git+file://${repo}?rev=${repo_revision}&shallow=1"
host="${repo}/hosts/csb1/configuration.nix"
compose="${repo}/hosts/csb1/docker/compose-spec.nix"
contract="${repo}/hosts/csb1/docker/janus/managed-service-production"
pharos_contract="${repo}/hosts/csb1/docker/janus/pharos-production"
secrets_nix="${repo}/secrets/secrets.nix"
zero_digest="sha256:$(printf '0%.0s' {1..64})"
activation="$(
  nix eval --json \
    "${flake_ref}#nixosConfigurations.csb1.config.inspr.janusHostSecrets.enable"
)"
if [ "${activation}" != "true" ]; then
  printf 'managed-service production activation is not enabled\n' >&2
  exit 1
fi

if grep -Fq "${zero_digest}" "${compose}"; then
  printf 'managed-service declaration still contains the release digest sentinel\n' >&2
  exit 1
fi

for file in "${contract}"/*.json; do
  jq -e . "${file}" >/dev/null
done
for file in "${contract}"/*.toml "${pharos_contract}"/*.toml; do
  nix eval --impure --json --expr \
    "builtins.fromTOML (builtins.readFile \"${file}\")" >/dev/null
done

python3 - "${contract}" "${pharos_contract}" <<'PY'
import hashlib
import json
import pathlib
import re
import struct
import sys
import tomllib

contract = pathlib.Path(sys.argv[1])
pharos = pathlib.Path(sys.argv[2])

scope = ("inspr", "janus", "nixcfg", "production")
canonical = b""
for component in ("janus-scope-v1", *scope):
    encoded = component.encode()
    canonical += struct.pack(">Q", len(encoded)) + encoded
canonical += b"\0\0"
scope_ref = "scp_" + hashlib.sha256(canonical).hexdigest()[:40]
if scope_ref != "scp_e3b09b6f7b8b2377d8c0e8b904043ef025b68d6b":
    raise SystemExit("managed-service scope reference drift")

secret_name = "MANAGED_SERVICE_CANARY_API_TOKEN"
secret_ref = "sec_" + hashlib.sha256(
    b"janus-secret-ref-v2\0"
    + scope_ref.encode()
    + b"\0"
    + secret_name.encode()
).hexdigest()[:20]
if secret_ref != "sec_4e32300270e0dda2d11a":
    raise SystemExit("managed-service secret reference drift")

catalog = json.loads((contract / "web-transaction-catalog.json").read_text())
if set(catalog) != {"schema", "schema_version", "entries"}:
    raise SystemExit("managed web catalog is not closed")
if catalog["schema"] != "inspr.janus.managed-web-transaction-catalog.v2":
    raise SystemExit("managed web catalog schema drift")
entries = catalog["entries"]
if len(entries) != 5:
    raise SystemExit("managed web catalog must contain exactly five lifecycle entries")
shapes = sorted(
    (entry["operation_kind"], entry["plan"]["source"]["mode"]) for entry in entries
)
if shapes != [
    ("create", "generated"),
    ("create", "import"),
    ("remove", "generated"),
    ("replace", "generated"),
    ("replace", "import"),
]:
    raise SystemExit("managed web catalog lifecycle coverage drift")
for entry in entries:
    if (
        entry["host_ref"] != "host_58f36c72a91e"
        or entry["service_ref"] != "svc_0bca8d31f7e2"
        or entry["slot_ref"] != "slot_49c0e8a17d63"
        or entry["plan"]["secret_ref"] != secret_ref
        or entry["plan"]["expected_scope_ref"] != scope_ref
        or entry["delivery"]["generation"] != 1
        or entry["delivery"]["revocation_epoch"] != 1
    ):
        raise SystemExit("managed web catalog authority drift")

env_contract = tomllib.loads((contract / "managed-env-files.toml").read_text())
profiles = env_contract["env_files"]
if len(profiles) != 1:
    raise SystemExit("managed-service consumer profile must remain singular")
profile = profiles[0]
if (
    profile["secret_ref"] != secret_ref
    or profile["consumer"]["consumer_ref"] != "consumer.managed_service_canary"
    or profile["consumer"]["reload"] != "none"
):
    raise SystemExit("managed-service consumer contract drift")

pharos_env = tomllib.loads((pharos / "managed-env-files.toml").read_text())
agent = next(
    (
        item
        for item in pharos_env["env_files"]
        if item["id"] == "profile.PHAROS_BEACON_HOST_58F36C72A91E_TOKEN"
    ),
    None,
)
if agent is None:
    raise SystemExit("managed host agent is missing from the Pharos token generation")
if (
    agent["secret_ref"] != "sec_f919b383ebe6a09dc87c"
    or agent["hash_sidecar"]["subject"] != "host_58f36c72a91e"
):
    raise SystemExit("managed host agent token contract drift")

policy = json.loads((contract / "release-channels-v1.json").read_text())
expected_policy = {
    "schema_version": 1,
    "policy_id": "janus-engine-release-v1",
    "policy_version": 3,
    "required_modes": ["production", "enterprise"],
    "deny_mode_downgrade": True,
    "channels": [
        {
            "name": "stable",
            "image": "ghcr.io/inspr-at/janus/janus-engine",
            "tag_prefix": "rust-engine-v",
            "tag_pattern": r"rust-engine-v[0-9]+\.[0-9]+\.[0-9]+",
            "repository": "inspr-at/janus",
            "signer_workflow": "inspr-at/janus/.github/workflows/rust.yml",
            "source_manifest_workflow": ".github/workflows/rust.yml",
            "certificate_identity_prefix": (
                "https://github.com/inspr-at/janus/"
                ".github/workflows/rust.yml@refs/tags/"
            ),
            "oidc_issuer": "https://token.actions.githubusercontent.com",
            "provenance_predicate_type": "https://slsa.dev/provenance/v1",
            "sbom_predicate_type": "https://spdx.dev/Document/v2.3",
        },
        {
            "name": "envelope-stable",
            "image": "ghcr.io/inspr-at/janus/janus-envelope",
            "tag_prefix": "go-envelope-v",
            "tag_pattern": r"go-envelope-v[1-9][0-9]*\.[0-9]+",
            "repository": "inspr-at/janus",
            "signer_workflow": "inspr-at/janus/.github/workflows/go-envelope.yml",
            "source_manifest_workflow": ".github/workflows/go-envelope.yml",
            "certificate_identity_prefix": (
                "https://github.com/inspr-at/janus/"
                ".github/workflows/go-envelope.yml@refs/tags/"
            ),
            "oidc_issuer": "https://token.actions.githubusercontent.com",
            "provenance_predicate_type": "https://slsa.dev/provenance/v1",
            "sbom_predicate_type": "https://spdx.dev/Document/v2.3",
        }
    ],
    # This impossible digest is the policy's permanent revocation canary.
    "revoked_digests": ["sha256:" + ("d" * 64)],
}
if policy != expected_policy:
    raise SystemExit("managed release policy drift")

for filename, channel, image, tag, expected_commit in (
    (
        "release-admission.json",
        "stable",
        "ghcr.io/inspr-at/janus/janus-engine",
        "rust-engine-v0.1.20",
        "65f64b187e398c472671bec9bd2f919ef20eb131",
    ),
    (
        "go-envelope-admission.json",
        "envelope-stable",
        "ghcr.io/inspr-at/janus/janus-envelope",
        "go-envelope-v1.176",
        "f4591af097098344b3844221c27f66fd774378c1",
    ),
):
    receipt = json.loads((contract / filename).read_text())
    if (
        receipt["schema_version"] != 1
        or receipt["policy_id"] != "janus-engine-release-v1"
        or receipt["policy_version"] != 3
        or receipt["channel"] != channel
        or receipt["mode"] != "production"
        or receipt["previous_mode"] != "production"
        or receipt["artifact"]["image"] != image
        or receipt["artifact"]["tag"] != tag
        or re.fullmatch(r"sha256:[0-9a-f]{64}", receipt["artifact"]["digest"])
        is None
        or receipt["artifact"]["development"] is not False
        or receipt["signature"]["verified"] is not True
        or receipt["provenance"]["verified"] is not True
        or receipt["sbom"]["verified"] is not True
        or receipt["source"]["verified"] is not True
        or receipt["source"]["commit"] != expected_commit
        or re.fullmatch(
            r"sha256:[0-9a-f]{64}", receipt["source"]["manifest_sha256"]
        )
        is None
        or re.fullmatch(
            r"sha256:[0-9a-f]{64}", receipt["source"]["bundle_sha256"]
        )
        is None
        or receipt["scanner"]["verified"] is not True
        or receipt["scanner"]["name"] != "trivy"
        or receipt["scanner"]["policy"] != "candidate_container_critical_high"
        or receipt["scanner"]["subject"]
        != f'{image}@{receipt["artifact"]["digest"]}'
        or re.fullmatch(
            r"sha256:[0-9a-f]{64}", receipt["scanner"]["summary_sha256"]
        )
        is None
        or type(receipt["scanner"]["critical"]) is not int
        or receipt["scanner"]["critical"] != 0
        or type(receipt["scanner"]["high"]) is not int
        or receipt["scanner"]["high"] != 0
    ):
        raise SystemExit(f"{filename} evidence drift")
PY

for name in \
  internal-token \
  pharos-signing-key \
  host-signing-key \
  age-identity \
  host-agent-token; do
  encrypted="${repo}/secrets/csb1-janus-managed-${name}.age"
  test -s "${encrypted}"
  test "$(wc -c <"${encrypted}" | tr -d ' ')" != "578"
  grep -Fq "\"csb1-janus-managed-${name}.age\".publicKeys = markus ++ csb1;" \
    "${secrets_nix}"
done

grep -Fq 'age.secrets.csb1-janus-managed-internal-token-pharos' "${host}"
grep -Fq 'path = "/run/agenix/csb1-janus-managed-internal-token-pharos";' "${host}"
test "$(grep -Fc 'file = ../../secrets/csb1-janus-managed-internal-token.age;' "${host}")" -eq 2
grep -Fq 'ownerUid = 65534;' "${host}"
grep -Fq 'beforeUnits = [ "janus-managed-canary.service" ];' "${host}"
grep -Fq 'composeFile = janusManagedComposeFile;' "${host}"
grep -Fq 'janus-managed-central.gid = 993;' "${host}"
grep -Fq 'pharos-container.gid = 992;' "${host}"
grep -Fq '"janus/managed/web-transaction-catalog.json" = {' "${host}"
grep -Fq '"janus/managed/go-envelope-admission.json" = {' "${host}"
test "$(
  nix eval \
    "${flake_ref}#nixosConfigurations.csb1.config.environment.etc.\"janus/managed/web-transaction-catalog.json\".mode" \
    --raw
)" = "0400"
test "$(
  nix eval \
    "${flake_ref}#nixosConfigurations.csb1.config.environment.etc.\"janus/managed/web-transaction-catalog.json\".user" \
    --raw
)" = "janus-managed-central"
test "$(
  nix eval \
    "${flake_ref}#nixosConfigurations.csb1.config.environment.etc.\"janus/managed/web-transaction-catalog.json\".group" \
    --raw
)" = "janus-managed-central"
projection_default="HASH_PROJECTION_GID=\${JANUS_PHAROS_HASH_PROJECTION_GID:-991}"
projection_call="\"\$consumer_uid\" \"\$HASH_PROJECTION_GID\""
grep -Fq "${projection_default}" \
  "${pharos_contract}/render-sidecars.sh"
grep -Fq "${projection_call}" \
  "${pharos_contract}/render-sidecars.sh"
grep -Fq 'ConditionPathExists' "${host}"
grep -Fq 'janus-managed-central-seed' "${host}"
grep -Fq 'systemd.services.janus-managed-transactiond' "${host}"
test "$(
  nix eval \
    "${flake_ref}#nixosConfigurations.csb1.config.systemd.services.janus-managed-transactiond.restartTriggers" \
    --json | jq 'length'
)" = "7"
grep -Fq 'Restart = "always";' "${host}"
grep -Fq 'profiles = [' "${compose}"
grep -Fq 'user = "100:101";' "${compose}"
grep -Fq 'user = "100:993";' "${compose}"
grep -Fq 'user = "65534:65534";' "${compose}"
test "$(grep -Fc '"991"' "${compose}")" -eq 2
grep -Fq 'network_mode = "none";' "${compose}"
grep -Fq 'read_only = true;' "${compose}"
grep -Fq '"ALL"' "${compose}"
grep -Fq 'no-new-privileges:true' "${compose}"
grep -Fq 'traefik.enable=false' "${compose}"
pharos_tag="$(
  awk '
    /^    pharosd = {/ { in_service = 1; next }
    in_service && /^    };/ { exit }
    in_service && /^      image = "/ {
      sub(/^.*pharosd:/, "")
      sub(/@sha256:.*$/, "")
      print
      exit
    }
  ' "${compose}"
)"
[[ "${pharos_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
pharos_tag_pattern="${pharos_tag//./\\.}"
grep -Fq "pharos/pharosd:${pharos_tag_pattern}@sha256" "${contract}/readiness.sh"
for binding in \
  'JANUS_MANAGED_SETUP_PHAROS_ORIGIN=https://pharos.barta.cm' \
  'JANUS_MANAGED_SETUP_PHAROS_RETURN_ORIGIN=https://pharos.barta.cm' \
  'JANUS_MANAGED_SETUP_INTERNAL_TOKEN_FILE=/run/janus/managed/internal-token' \
  'JANUS_MANAGED_SETUP_VERIFICATION_KEYS_FILE=/etc/janus/managed/pharos-verification-keys.json' \
  'JANUS_MANAGED_SETUP_MANIFEST_PATHS=/managed-services/manifest.json' \
  'JANUS_MANAGED_WEB_TRANSACTION_SOCKET=/run/janus-managed-central/transaction.sock' \
  'JANUS_MANAGED_HOST_TOKEN_GENERATION_DIR=/run/pharos/beacon-token-hashes' \
  'JANUS_MANAGED_HOST_ENVELOPE_OUTBOX_DIR=/var/lib/janus-managed-central/outbox' \
  'PHAROS_MANAGED_SETUP_SIGNING_KEY_FILE=/run/pharos/managed-setup-signing-key' \
  'PHAROS_MANAGED_SETUP_JANUS_ORIGIN=https://vault.barta.cm' \
  'PHAROS_MANAGED_SETUP_INTERNAL_TOKEN_FILE=/run/pharos/managed-setup-internal-token'; do
  grep -Fq "${binding}" "${compose}"
done

# OPS-127: compose cannot parse the nix spec; feed it the closure's rendered
# JSON (identical content plus the module-injected dns keys).
rendered=$(mktemp)
nix eval --json "${repo}#nixosConfigurations.csb1.config.nixcfg.composeStack.renderedSpec" >"${rendered}"
compose_json=$(
  docker compose \
    -f "${rendered}" \
    config \
    --no-interpolate \
    --no-env-resolution \
    --no-path-resolution \
    --format json
)
go_artifact_tag=$(
  jq -er '.artifact.tag | select(test("^go-envelope-v[1-9][0-9]*\\.[0-9]+$"))' \
    "${contract}/go-envelope-admission.json"
)
go_artifact_digest=$(
  jq -er '.artifact.digest | select(test("^sha256:[0-9a-f]{64}$"))' \
    "${contract}/go-envelope-admission.json"
)
go_image="$(jq -er '.services.janus.image' <<<"${compose_json}")"
test "${go_image}" = \
  "ghcr.io/inspr-at/janus/janus-envelope:${go_artifact_tag}@${go_artifact_digest}"
go_tag_pattern="${go_artifact_tag//./\\.}"
grep -Fq "janus-envelope:${go_tag_pattern}@sha256" \
  "${contract}/readiness.sh"
rust_artifact_digest=$(
  jq -er '.artifact.digest | select(test("^sha256:[0-9a-f]{64}$"))' \
    "${contract}/release-admission.json"
)
rust_transaction_image="$(
  jq -er '.services["janus-managed-transactiond"].image' <<<"${compose_json}"
)"
jq -e \
  --arg artifact_digest "${rust_artifact_digest}" \
  --arg transaction_image "${rust_transaction_image}" \
  '
  def closed_bind($target; $read_only):
    any(.volumes[];
      .type == "bind"
      and .target == $target
      and ((.read_only // false) == $read_only)
      and .bind.create_host_path == false
    );
  .services["janus-managed-transactiond"] as $transaction
  | .services.janus as $janus
  | .services.pharosd as $pharos
  | .services["janus-managed-canary"] as $canary
  | $transaction.profiles == ["janus-managed-service"]
  and $transaction.restart == "no"
  and $transaction.init == true
  and $transaction.user == "100:993"
  and $transaction.read_only == true
  and $transaction.network_mode == "none"
  and $transaction.cap_drop == ["ALL"]
  and ($transaction.security_opt | index("no-new-privileges:true") != null)
  and $transaction.pids_limit == 64
  and $transaction.mem_limit == "128m"
  and $transaction.cpus == "0.50"
  and $transaction.healthcheck.test == ["CMD", "/usr/local/bin/janusd-use", "--help"]
  and $transaction.image == $transaction_image
  and ($transaction_image | endswith("@" + $artifact_digest))
  and (
    $transaction.environment
    | index("JANUS_RELEASE_ARTIFACT_DIGEST=" + $artifact_digest) != null
  )
  and ($transaction | closed_bind("/var/lib/janus-managed-central"; false))
  and ($transaction | closed_bind("/run/janus-managed-central"; false))
  and ($transaction | closed_bind("/run/agenix/csb1-janus-managed-host-signing-key"; true))
  and ($transaction | closed_bind("/run/agenix/csb1-janus-managed-age-identity"; true))
  and ($transaction | closed_bind("/etc/janus/managed/release-channels-v1.json"; true))
  and ($transaction | closed_bind("/etc/janus/managed/release-admission.json"; true))
  and $janus.user == "100:101"
  and ($janus.group_add | index("991") != null)
  and any($janus.volumes[];
    .source == "/run/agenix/csb1-janus-managed-internal-token"
    and .target == "/run/janus/managed/internal-token"
    and .read_only == true
    and .bind.create_host_path == false
  )
  and ($janus | closed_bind("/run/janus-managed-central"; true))
  and ($janus | closed_bind("/var/lib/janus-managed-central/outbox"; true))
  and $pharos.user == "10001:992"
  and ($pharos.group_add | index("991") != null)
  and any($pharos.volumes[];
    .source == "/run/agenix/csb1-janus-managed-internal-token-pharos"
    and .target == "/run/pharos/managed-setup-internal-token"
    and .read_only == true
    and .bind.create_host_path == false
  )
  and ($pharos | closed_bind("/run/pharos/managed-setup-signing-key"; true))
  and ($pharos | closed_bind("/run/pharos/managed-setup-internal-token"; true))
  and $canary.init == true
  and $canary.user == "65534:65534"
  and $canary.read_only == true
  and $canary.network_mode == "none"
  and $canary.cap_drop == ["ALL"]
  and ($canary.security_opt | index("no-new-privileges:true") != null)
  and $canary.pids_limit == 32
  and $canary.mem_limit == "32m"
  and $canary.cpus == "0.10"
  and ($canary | closed_bind("/run/secrets/canary-api-token"; true))
' <<<"${compose_json}" >/dev/null

grep -Fq 'host_58f36c72a91e' "${pharos_contract}/render-sidecars.sh"
grep -Fq 'sudo -n cat /run/agenix/csb1-janus-managed-host-agent-token' \
  "${pharos_contract}/import-existing-agenix-beacons.sh"

if rg -n '(private_key_base64url|AGE-SECRET-KEY|CANARY_API_TOKEN=|PHAROS_TOKEN=)' \
  "${host}" \
  "${compose}" \
  "${contract}" \
  "${pharos_contract}/secretspec.toml" \
  "${pharos_contract}/managed-env-files.toml" \
  "${pharos_contract}/render-sidecars.sh" \
  "${pharos_contract}/import-existing-agenix-beacons.sh" >/dev/null; then
  printf 'managed-service declaration contains a forbidden value-shaped literal\n' >&2
  exit 1
fi

printf 'managed_secret_production_preflight=ok activation=%s value_returned=false\n' \
  "${activation}"
