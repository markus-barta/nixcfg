#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${repo}" =~ [[:space:]#?] ]]; then
  printf 'repository path is not safe for a local Git flake URL\n' >&2
  exit 1
fi
if git -C "${repo}" diff --quiet &&
  git -C "${repo}" diff --cached --quiet &&
  [[ -z "$(git -C "${repo}" ls-files --others --exclude-standard)" ]]; then
  repo_revision="$(git -C "${repo}" rev-parse HEAD)"
  flake_ref="git+file://${repo}?rev=${repo_revision}&shallow=1"
else
  flake_ref="path:${repo}"
fi
export JANUS_FLEET_SECRET_PINNED_FLAKE_REF="${flake_ref}"
module="${repo}/modules/janus-fleet-secrets/default.nix"
fixture="${repo}/tests/janus-fleet-secret-module-eval.nix"
fixture_host="${repo}/tests/fixtures/janus-fleet-secret-host.nix"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"

nix-instantiate --parse "${module}" >/dev/null
nix eval --impure --raw --file "${fixture}" |
  grep -Fqx 'janus_fleet_secret_module_eval=ok'

test "$(grep -Fc 'inspr.janusFleetSecrets.consumers.fixture-consumer = "shared-alert-url";' "${fixture_host}")" -eq 1
grep -Fq 'projectionRoot = "/run/janus-projections/managed-service-environment"' "${module}"
grep -Fq 'serviceConfig.LoadCredential = lib.mkAfter' "${module}"
grep -Fq 'requiredBy = units' "${module}"
grep -Fq 'before = units' "${module}"
# These dollar expressions are intentionally matched as literal Nix source.
# shellcheck disable=SC2016
grep -Fq 'test -f "$projected_file"' "${module}"
# shellcheck disable=SC2016
grep -Fq 'test -L "$projected_file"' "${module}"
grep -Fq "bin/stat -c '%a'" "${module}"
grep -Fq 'reason_code=projection_missing value_returned=false' "${module}"
grep -Fq 'systemd-credential://janus-shared-alert-url' "${runbook}"

if grep -Eq '(secretValue|credentialValue|inlineValue|environmentFile|sourcePath)[[:space:]]*=' "${module}"; then
  printf 'fleet-secret module exposes forbidden value or caller-path input\n' >&2
  exit 1
fi
if grep -Eq '(age\.secrets|janusd-use|--profile|--permit|--destination|--output)' "${module}"; then
  printf 'fleet-secret module crossed the Janus projection or agenix boundary\n' >&2
  exit 1
fi
if grep -Fq 'ConditionPathExists' "${module}"; then
  printf 'missing projection would skip rather than fail the required gate\n' >&2
  exit 1
fi

printf 'janus_fleet_secret_module=ok hosts=2 binding=LoadCredential value_returned=false\n'
