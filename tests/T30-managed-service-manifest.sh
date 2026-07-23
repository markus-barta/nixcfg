#!/usr/bin/env bash
# T30-managed-service-manifest.sh
# Description: Validate the strict value-free csb1 managed-service declaration.
# Related PPM issue: JANUS-354

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0
INVALID_LABEL_LOG="$(mktemp)"

cleanup() {
  rm -f "$INVALID_LABEL_LOG"
}
trap cleanup EXIT

pass() {
  echo -e "${GREEN}PASS${NC} $1"
  ((PASSED += 1))
}

fail() {
  echo -e "${RED}FAIL${NC} $1"
  ((FAILED += 1))
}

check_jq() {
  local label="$1"
  local expression="$2"

  if jq -e "$expression" >/dev/null <<<"$MANIFEST_JSON"; then
    pass "$label"
  else
    fail "$label"
  fi
}

cd "$REPO_ROOT"

echo "=== T30: Managed-service declaration generation ==="
echo

for dependency in jq rg; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "$dependency is required for this test"
    exit 1
  fi
done

MANIFEST_JSON="$(nix eval '.#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.generated' --json)"
SECOND_MANIFEST_JSON="$(nix eval '.#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.generated' --json)"
FINGERPRINT="$(nix eval '.#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.declarationFingerprint' --raw)"
SOURCE_PATH="$(nix eval '.#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.source' --raw)"
ETC_SOURCE="$(nix eval '.#nixosConfigurations.csb1.config.environment.etc."pharos/managed-service-declarations.json".source' --raw)"
PUBLISHER_BEFORE="$(nix eval '.#nixosConfigurations.csb1.config.systemd.services.pharos-managed-service-declarations.before' --json)"
PUBLISHER_EXEC="$(nix eval '.#nixosConfigurations.csb1.config.systemd.services.pharos-managed-service-declarations.serviceConfig.ExecStart' --raw)"
COMPOSE_FILE="$REPO_ROOT/hosts/csb1/docker/docker-compose.yml"

check_jq "schema and producer are exact v1 values" '
  .schema == "inspr.pharos.managed-service-declarations.v1"
  and .schema_version == 1
  and .generated_by == "nixcfg"
'
check_jq "host and declaration use opaque references" '
  (.host_ref | test("^host_[a-z0-9_]{8,}$"))
  and (.declaration_fingerprint | test("^decl_[a-f0-9]{64}$"))
'
check_jq "one reviewed Compose service and slot are declared" '
  .services == [{
    "runtime_kind":"compose",
    "safe_label":"Managed service canary",
    "service_ref":"svc_0bca8d31f7e2",
    "slots":[{
      "allowed_sources":["generated","import"],
      "consumer_kind":"managed_service",
      "delivery":{"kind":"private_env_file","profile_ref":"delivery_2d7a0f63c951"},
      "health":{"probe":"compose_healthcheck","profile_ref":"health_918d0ce7b4a2"},
      "reload":{"method":"compose_recreate","profile_ref":"reload_65bc19f3a087"},
      "safe_label":"Canary API token",
      "slot_ref":"slot_49c0e8a17d63"
    }]
  }]
'
# shellcheck disable=SC2016 # jq expression is intentionally literal.
check_jq "manifest fields are closed and value-free" '
  ([paths(scalars) as $path | $path[-1]]
    | all(. != "secret"
      and . != "value"
      and . != "ciphertext"
      and . != "private_key"
      and . != "permit"
      and . != "token"
      and . != "command"
      and . != "path"))
'

if nix eval --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    base = flake.nixosConfigurations.csb1;
    badLabel = "bad" + builtins.fromJSON "\"\\u0085\"" + "label";
    invalid = base.extendModules {
      modules = [
        ({ lib, ... }: {
          services.janus.managedServiceManifest.services = lib.mkForce [
            {
              serviceRef = "svc_0bca8d31f7e2";
              safeLabel = badLabel;
              runtimeKind = "compose";
              slots = [
                {
                  slotRef = "slot_49c0e8a17d63";
                  safeLabel = "Canary API token";
                  deliveryProfileRef = "delivery_2d7a0f63c951";
                  reloadProfileRef = "reload_65bc19f3a087";
                  healthProfileRef = "health_918d0ce7b4a2";
                  allowedSources = [ "generated" "import" ];
                }
              ];
            }
          ];
        })
      ];
    };
  in
  invalid.config.system.build.toplevel.drvPath
' --raw >/dev/null 2>"$INVALID_LABEL_LOG"; then
  fail "Nix rejects C1 control characters before publishing"
elif rg -q 'managed-service safe labels must be bounded, trimmed, and control-free' "$INVALID_LABEL_LOG"; then
  pass "Nix rejects C1 control characters before publishing"
else
  cat "$INVALID_LABEL_LOG" >&2
  fail "Nix rejects C1 control characters before publishing"
fi

if [[ "$(jq -cS . <<<"$MANIFEST_JSON")" == "$(jq -cS . <<<"$SECOND_MANIFEST_JSON")" ]]; then
  pass "repeated evaluation is deterministic"
else
  fail "repeated evaluation is deterministic"
fi

if [[ "$(jq -r .declaration_fingerprint <<<"$MANIFEST_JSON")" == "$FINGERPRINT" ]]; then
  pass "published fingerprint matches generated body"
else
  fail "published fingerprint matches generated body"
fi

if [[ "$SOURCE_PATH" == /nix/store/*managed-service-declarations.json ]]; then
  pass "manifest source is a generated Nix store JSON file"
else
  fail "manifest source is a generated Nix store JSON file: got $SOURCE_PATH"
fi

if [[ "$ETC_SOURCE" == "$SOURCE_PATH" ]]; then
  pass "environment.etc publishes the exact generated source"
else
  fail "environment.etc publishes the exact generated source"
fi

if jq -e 'index("docker.service") != null' <<<"$PUBLISHER_BEFORE" >/dev/null &&
  [[ "$PUBLISHER_EXEC" == /nix/store/*publish-managed-service-declarations ]]; then
  pass "atomic runtime projection is ordered before Docker"
else
  fail "atomic runtime projection is ordered before Docker"
fi

if [[ ! -e "$SOURCE_PATH" ]]; then
  pass "store artifact realization is correctly deferred to the Linux host"
elif jq -e --argjson generated "$MANIFEST_JSON" '$generated == .' "$SOURCE_PATH" >/dev/null; then
  pass "realized store artifact exactly matches the evaluated manifest"
else
  fail "realized store artifact exactly matches the evaluated manifest"
fi

if rg -q 'PHAROS_MANAGED_SERVICE_MANIFEST_PATHS=/managed-services/manifest\.json' "$COMPOSE_FILE" &&
  rg -q '/run/pharos/managed-service-declarations:/managed-services:ro' "$COMPOSE_FILE"; then
  pass "pharosd receives the live declaration directory through a read-only mount"
else
  fail "pharosd receives the live declaration directory through a read-only mount"
fi

echo
echo "=== Summary ==="
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
