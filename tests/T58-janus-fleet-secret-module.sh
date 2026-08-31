#!/usr/bin/env bash
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run with: nix shell nixpkgs#bash nixpkgs#coreutils --command bash %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi
if ! stat --version 2>/dev/null | grep -Fq 'GNU coreutils'; then
  printf '%s: GNU coreutils stat is required. Run with: nix shell nixpkgs#bash nixpkgs#coreutils --command bash %s\n' \
    "${0##*/}" "$0" >&2
  exit 2
fi

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
validator="${repo}/modules/janus-fleet-secrets/validate-projection.sh"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"
workflow="${repo}/.github/workflows/check.yml"

nix-instantiate --parse "${module}" >/dev/null
nix eval --impure --raw --file "${fixture}" |
  grep -Fqx 'janus_fleet_secret_module_eval=ok'

test "$(grep -Fc 'inspr.janusFleetSecrets.consumers.fixture-consumer = "shared-alert-url";' "${fixture_host}")" -eq 1
grep -Fq 'projectionRoot = "/run/janus-projections/managed-service-environment"' "${module}"
grep -Fq 'serviceConfig.LoadCredential = lib.mkAfter' "${module}"
grep -Fq 'requiredBy = units' "${module}"
grep -Fq 'before = units' "${module}"
if grep -Fq 'RemainAfterExit' "${module}"; then
  printf 'projection gate must be inactive after each check so consumer starts revalidate it\n' >&2
  exit 1
fi
grep -Fq 'systemd-credential://janus-shared-alert-url' "${runbook}"
grep -Fq \
  'run: nix shell nixpkgs#bash nixpkgs#coreutils --command bash tests/T58-janus-fleet-secret-module.sh' \
  "${workflow}"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/janus-fleet-secret.XXXXXX")"
cleanup() {
  chmod -R u+rwX "${test_root}" 2>/dev/null || true
  rm -rf "${test_root}"
}
trap cleanup EXIT
private_root="${test_root}/managed-service-environment"
host_root="${private_root}/hsb1"
projection="${host_root}/shared-alert-url.env"
mkdir -p "${host_root}"
chmod 700 "${test_root}" "${private_root}" "${host_root}"
expected_uid="$(stat -c '%u' "${test_root}")"
expected_gid="$(stat -c '%g' "${test_root}")"
printf 'fixture bytes are deliberately not a credential\n' >"${projection}"
chmod 600 "${projection}"

run_validator() {
  bash "${validator}" stat "${expected_uid}" "${expected_gid}" "${test_root}" "${projection}"
}
expect_rejected() {
  local reason="$1"
  shift
  if "$@" >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf '%s fixture unexpectedly passed\n' "${reason}" >&2
    exit 1
  fi
  grep -Fq "reason_code=${reason} value_returned=false" "${test_root}/stderr"
}

run_validator
mv "${projection}" "${projection}.old"
expect_rejected projection_missing run_validator
mv "${projection}.old" "${projection}"
chmod 640 "${projection}"
expect_rejected projection_not_private run_validator
chmod 600 "${projection}"
wrong_owner_stat="${test_root}/stat-wrong-owner"
cat >"${wrong_owner_stat}" <<EOF
#!/usr/bin/env bash
if [ "\$2" = '%u:%g' ] && [ "\$4" = '${projection}' ]; then
  printf '%s:%s\n' '$((expected_uid + 1))' '${expected_gid}'
  exit 0
fi
exec stat "\$@"
EOF
chmod 700 "${wrong_owner_stat}"
expect_rejected projection_owner_mismatch bash "${validator}" "${wrong_owner_stat}" \
  "${expected_uid}" "${expected_gid}" "${test_root}" "${projection}"
wrong_parent_owner_stat="${test_root}/stat-wrong-parent-owner"
cat >"${wrong_parent_owner_stat}" <<EOF
#!/usr/bin/env bash
if [ "\$2" = '%u:%g' ] && [ "\$4" = '${private_root}' ]; then
  printf '%s:%s\n' '$((expected_uid + 1))' '${expected_gid}'
  exit 0
fi
exec stat "\$@"
EOF
chmod 700 "${wrong_parent_owner_stat}"
expect_rejected projection_parent_owner_mismatch bash "${validator}" \
  "${wrong_parent_owner_stat}" "${expected_uid}" "${expected_gid}" "${test_root}" "${projection}"
chmod 750 "${host_root}"
expect_rejected projection_parent_not_private run_validator
chmod 700 "${host_root}"
mv "${private_root}" "${private_root}.missing"
expect_rejected projection_parent_missing run_validator
mv "${private_root}.missing" "${private_root}"
mv "${host_root}" "${host_root}.real"
ln -s "${host_root}.real" "${host_root}"
expect_rejected projection_parent_symlink run_validator
rm "${host_root}"
mv "${host_root}.real" "${host_root}"
run_validator
mv "${projection}" "${projection}.old"
ln -s "${projection}.old" "${projection}"
expect_rejected projection_not_regular run_validator
rm "${projection}"
mv "${projection}.old" "${projection}"
run_validator
replacement="${host_root}/replacement"
printf 'replacement fixture bytes\n' >"${replacement}"
chmod 644 "${replacement}"
mv "${replacement}" "${projection}"
expect_rejected projection_not_private run_validator

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
