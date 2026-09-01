#!/usr/bin/env bash
# T30-managed-service-manifest.sh
# Description: Validate the strict value-free csb1 managed-service declaration.
# Related PPM issue: JANUS-354

set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

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

for dependency in git jq rg; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "$dependency is required for this test"
    exit 1
  fi
done

if [[ "${REPO_ROOT}" =~ [[:space:]#?] ]]; then
  printf 'repository path is not safe for a local Git flake URL\n' >&2
  exit 1
fi
REPO_REVISION="$(git rev-parse HEAD)"
FLAKE_REF="git+file://${REPO_ROOT}?rev=${REPO_REVISION}&shallow=1"
export JANUS_PINNED_FLAKE_REF="${FLAKE_REF}"
MANIFEST_JSON="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.generated" --json)"
SECOND_MANIFEST_JSON="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.generated" --json)"
FINGERPRINT="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.declarationFingerprint" --raw)"
SOURCE_PATH="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.services.janus.managedServiceManifest.source" --raw)"
ETC_SOURCE="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.environment.etc.\"pharos/managed-service-declarations.json\".source" --raw)"
PUBLISHER_BEFORE="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.systemd.services.pharos-managed-service-declarations.before" --json)"
PUBLISHER_EXEC="$(nix eval "${FLAKE_REF}#nixosConfigurations.csb1.config.systemd.services.pharos-managed-service-declarations.serviceConfig.ExecStart" --raw)"
COMPOSE_FILE="$REPO_ROOT/hosts/csb1/docker/compose-spec.nix"

check_jq "schema and producer are exact v2 values" '
  .schema == "inspr.pharos.managed-service-declarations.v1"
  and .schema_version == 2
  and .generated_by == "nixcfg"
'
check_jq "host and declaration use opaque references" '
  (.host_ref | test("^host_[a-z0-9_]{8,}$"))
  and (.declaration_fingerprint | test("^decl_[a-f0-9]{64}$"))
'
check_jq "the canary and three fixed PPM slots are declared" '
  .services == [{
    "runtime_kind":"compose",
    "safe_label":"Managed service canary",
    "service_ref":"svc_0bca8d31f7e2",
    "slots":[{
      "allowed_sources":["generated","import"],
      "binding_state":"required",
      "consumer_kind":"managed_service",
      "delivery":{"kind":"private_env_file","profile_ref":"delivery_2d7a0f63c951"},
      "detach":{"method":"compose_stop_and_verify","profile_ref":"detach_8a0f4e271c93"},
      "health":{"probe":"compose_healthcheck","profile_ref":"health_918d0ce7b4a2"},
      "reload":{"method":"compose_recreate","profile_ref":"reload_65bc19f3a087"},
      "safe_label":"Canary API token",
      "slot_ref":"slot_49c0e8a17d63"
    }]
  },{
    "runtime_kind":"compose",
    "safe_label":"PPM",
    "service_ref":"svc_616c1af8cc7f4556975b",
    "slots":[{
      "allowed_sources":["import"],
      "binding_state":"required",
      "consumer_kind":"managed_service",
      "delivery":{"kind":"private_env_file","profile_ref":"delivery_572ad50f794e"},
      "detach":{"method":"compose_stop_and_verify","profile_ref":"detach_aa95b35a8b11"},
      "health":{"probe":"compose_healthcheck","profile_ref":"health_c9ac45927f59"},
      "reload":{"method":"compose_recreate","profile_ref":"reload_869d0c7c8106"},
      "safe_label":"PPM OIDC client secret",
      "slot_ref":"slot_25e403cccaaf015f30cb"
    },{
      "allowed_sources":["import"],
      "binding_state":"required",
      "consumer_kind":"managed_service",
      "delivery":{"kind":"private_env_file","profile_ref":"delivery_8089afb7e6e7"},
      "detach":{"method":"compose_stop_and_verify","profile_ref":"detach_d5c3f3d7461a"},
      "health":{"probe":"compose_healthcheck","profile_ref":"health_b597b0dc3340"},
      "reload":{"method":"compose_recreate","profile_ref":"reload_9abf75ea254d"},
      "safe_label":"PPM SMTP password",
      "slot_ref":"slot_4f7e86b99497776adf95"
    },{
      "allowed_sources":["import"],
      "binding_state":"required",
      "consumer_kind":"managed_service",
      "delivery":{"kind":"private_env_file","profile_ref":"delivery_ee3ee55a5691"},
      "detach":{"method":"compose_stop_and_verify","profile_ref":"detach_e1eed9bed55a"},
      "health":{"probe":"compose_healthcheck","profile_ref":"health_79a4d461b66d"},
      "reload":{"method":"compose_recreate","profile_ref":"reload_97c795963d1b"},
      "safe_label":"PPM encryption key",
      "slot_ref":"slot_6e7523d1b57919248919"
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

DETACHED_MANIFEST_JSON="$(nix eval --impure --json --expr '
  let
    flake = builtins.getFlake (builtins.getEnv "JANUS_PINNED_FLAKE_REF");
    base = flake.nixosConfigurations.csb1;
    detached = base.extendModules {
      modules = [
        ({ lib, ... }: {
          services.janus.managedServiceManifest.services = lib.mkForce [
            {
              serviceRef = "svc_0bca8d31f7e2";
              safeLabel = "Canary service";
              runtimeKind = "compose";
              slots = [
                {
                  slotRef = "slot_49c0e8a17d63";
                  safeLabel = "Canary API token";
                  deliveryProfileRef = "delivery_2d7a0f63c951";
                  reloadProfileRef = "reload_65bc19f3a087";
                  healthProfileRef = "health_918d0ce7b4a2";
                  detachProfileRef = "detach_8a0f4e271c93";
                  bindingState = "detached";
                  allowedSources = [ ];
                }
              ];
            }
          ];
        })
      ];
    };
  in
  detached.config.services.janus.managedServiceManifest.generated
')"
if jq -e '
  .services[0].slots[0].binding_state == "detached"
  and .services[0].slots[0].allowed_sources == []
  and .services[0].slots[0].detach.method == "compose_stop_and_verify"
' <<<"$DETACHED_MANIFEST_JSON" >/dev/null; then
  pass "reviewed detach is explicit and removes all creation sources"
else
  fail "reviewed detach is explicit and removes all creation sources"
fi

if nix eval --impure --expr '
  let
    flake = builtins.getFlake (builtins.getEnv "JANUS_PINNED_FLAKE_REF");
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
                  detachProfileRef = "detach_8a0f4e271c93";
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
