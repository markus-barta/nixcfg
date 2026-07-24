#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${repo}/hosts/csb1/configuration.nix"
compose="${repo}/hosts/csb1/docker/docker-compose.yml"
contract="${repo}/hosts/csb1/docker/janus/managed-service-production"
pharos_contract="${repo}/hosts/csb1/docker/janus/pharos-production"
secrets_nix="${repo}/secrets/secrets.nix"

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

grep -Fq 'group = "janus-managed-runtime";' "${host}"
grep -Fq 'mode = "0440";' "${host}"
grep -Fq 'ownerUid = 65534;' "${host}"
grep -Fq 'beforeUnits = [ "janus-managed-canary.service" ];' "${host}"
grep -Fq 'ConditionPathExists' "${host}"
grep -Fq 'janus-managed-central-seed' "${host}"
grep -Fq 'profiles: ["janus-managed-service"]' "${compose}"
grep -Fq 'user: "65534:65534"' "${compose}"
grep -Fq 'network_mode: "none"' "${compose}"
grep -Fq 'read_only: true' "${compose}"
grep -Fq 'cap_drop: ["ALL"]' "${compose}"
grep -Fq 'no-new-privileges:true' "${compose}"
grep -Fq 'traefik.enable=false' "${compose}"
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

printf 'managed_secret_production_preflight=ok activation=false value_returned=false\n'
