#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/pharos-guarded-deploy/default.nix"
apply="$repo_root/modules/pharos-guarded-deploy/apply.sh"
rollback="$repo_root/modules/pharos-guarded-deploy/rollback.sh"
bootstrap="$repo_root/modules/pharos-guarded-deploy/bootstrap.sh"
bootstrap_roles="$repo_root/modules/pharos-guarded-deploy/bootstrap-roles.sh"
review="$repo_root/modules/pharos-guarded-deploy/review.sh"
system_update="$repo_root/modules/pharos-guarded-deploy/system-update.sh"
action_agent="$repo_root/modules/pharos-guarded-deploy/action-agent.sh"
host_config="$repo_root/hosts/hsb8/configuration.nix"
host_compose="$repo_root/hosts/hsb8/docker/compose-spec.nix"

bash -n "$apply" "$rollback" "$bootstrap" "$bootstrap_roles" "$review" "$system_update" "$action_agent"

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

apply_ref="sec_$(printf 'pharos-deploy\0PHAROS_APPLY_HSB8' | digest | cut -c1-20)"
rollback_ref="sec_$(printf 'pharos-deploy\0PHAROS_ROLLBACK_HSB8' | digest | cut -c1-20)"
update_ref="sec_$(printf 'pharos-deploy\0PHAROS_UPDATE_HSB8' | digest | cut -c1-20)"
[ "$apply_ref" != "$rollback_ref" ]
[ "$apply_ref" != "$update_ref" ]
[ "$rollback_ref" != "$update_ref" ]
grep -Fq "applySecretRef = \"$apply_ref\";" "$host_config"
grep -Fq "rollbackSecretRef = \"$rollback_ref\";" "$host_config"
grep -Fq "updateSecretRef = \"$update_ref\";" "$host_config"

grep -Fq 'classification = "high_value"' "$module"
grep -Fq 'allowed_args = []' "$module"
[ "$(grep -Fc 'allowed_args = []' "$module")" -eq 3 ]
# These are literal Nix and shell source assertions.
# shellcheck disable=SC2016
grep -Fq 'profile.${applySecretName}' "$module"
# shellcheck disable=SC2016
grep -Fq 'profile.${rollbackSecretName}' "$module"
grep -Fq -- '--egress hook_guarded' "$review"
grep -Fq -- '--revoke-approval' "$review"
grep -Fq -- '--permit-ttl-seconds 240' "$review"
grep -Fq 'profile.@UPDATE_SECRET_NAME@' "$review"
grep -Fq "stage='approval'" "$review"
grep -Fq 'pharos_guarded_deploy=failed action=%s stage=%s failure_gate=%s value_returned=false' "$review"
grep -Fq 'pharos-host-action-agent' "$module"
grep -Fq 'pharos-guarded-system-update' "$module"
if grep -Fq 'unsafe_disabled_dev' "$review" "$bootstrap_roles"; then
  echo 'disabled Janus role authorization found in guarded deployment path' >&2
  exit 1
fi

test_root=$(mktemp -d)
cleanup_test_root() {
  rm -rf "$test_root"
}
trap cleanup_test_root EXIT
mkdir -p "$test_root/bin" "$test_root/state/requests" "$test_root/manifests"
call_log="$test_root/calls.tsv"

cat >"$test_root/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = '-u' ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
EOF
cat >"$test_root/bin/janusd-use" <<'EOF'
#!/usr/bin/env bash
set -eu
for name in JANUS_SCOPE_ORGANIZATION JANUS_SCOPE_PROJECT JANUS_SCOPE_REPOSITORY JANUS_SCOPE_ENVIRONMENT JANUS_ROLE_AUTHORIZATION_MODE JANUS_ROLE_BINDINGS_ROOT JANUS_ROLE_AUDIT_FILE JANUS_RELEASE_EXECUTOR; do
  [ -n "${!name:-}" ] || exit 64
done
[ -z "${JANUS_ADMIN_EXECUTOR+x}" ] || exit 66
printf 'use\t%s\t%s\t%s/%s/%s/%s\t%s\t%s\n' "$1" "${2:-}" \
  "$JANUS_SCOPE_ORGANIZATION" "$JANUS_SCOPE_PROJECT" "$JANUS_SCOPE_REPOSITORY" "$JANUS_SCOPE_ENVIRONMENT" \
  "$JANUS_ROLE_AUTHORIZATION_MODE" "$JANUS_RELEASE_EXECUTOR" >>"$TEST_CALL_LOG"
if [ "$1" = run ] && [ "${2:-}" = preflight ]; then
  printf 'reason_code=ok value_returned=false\n'
else
  printf 'value_returned=false\n'
  printf 'janusd-use run completed exit_success=true exit_code=Some(0) reason_code=ok value_returned=false\n' >&2
fi
EOF
cat >"$test_root/bin/janusd-admin" <<'EOF'
#!/usr/bin/env bash
set -eu
for name in JANUS_SCOPE_ORGANIZATION JANUS_SCOPE_PROJECT JANUS_SCOPE_REPOSITORY JANUS_SCOPE_ENVIRONMENT JANUS_ROLE_AUTHORIZATION_MODE JANUS_ROLE_BINDINGS_ROOT JANUS_ROLE_AUDIT_FILE JANUS_RELEASE_EXECUTOR; do
  [ -n "${!name:-}" ] || exit 64
done
[ -z "${JANUS_ADMIN_EXECUTOR+x}" ] || exit 66
printf 'admin\t%s\t%s\t%s/%s/%s/%s\t%s\t%s\n' "$1" "${2:-}" \
  "$JANUS_SCOPE_ORGANIZATION" "$JANUS_SCOPE_PROJECT" "$JANUS_SCOPE_REPOSITORY" "$JANUS_SCOPE_ENVIRONMENT" \
  "$JANUS_ROLE_AUTHORIZATION_MODE" "$JANUS_RELEASE_EXECUTOR" >>"$TEST_CALL_LOG"
case "${1:-} ${2:-}" in
'approve issue') printf 'approval_id=appr_test\n' ;;
'approve permit') printf 'permit_id=use_test\n' ;;
*) exit 65 ;;
esac
EOF
chmod +x "$test_root/bin/id" "$test_root/bin/janusd-use" "$test_root/bin/janusd-admin"

render_review() {
  local output=$1
  local organization=$2
  local role_root=$3
  python3 - "$review" "$output" "$test_root" "$organization" "$role_root" <<'PY'
from pathlib import Path
import re
import sys

source, output, root, organization, role_root = sys.argv[1:]
replacements = {
    "@HOST@": "inspr397-target",
    "@JANUSD_USE@": f"{root}/bin/janusd-use",
    "@JANUSD_ADMIN@": f"{root}/bin/janusd-admin",
    "@SCOPE_ORGANIZATION@": organization,
    "@SCOPE_PROJECT@": "pharos" if organization else "",
    "@SCOPE_REPOSITORY@": "inspr397-target" if organization else "",
    "@SCOPE_ENVIRONMENT@": "lab" if organization else "",
    "@ROLE_BINDINGS_ROOT@": role_root,
    "@ROLE_AUDIT_FILE@": f"{root}/state/role-audit.jsonl" if role_root else "",
    "@ROLE_POLICY_FILE@": "",
    "@USE_PRINCIPAL@": "inspr397-operator" if role_root else "",
    "@ADMIN_PRINCIPAL@": "inspr397-approver" if role_root else "",
    "@STATE_DIR@": f"{root}/state",
    "@PROFILE_MANIFEST@": f"{root}/manifests/managed-commands.toml",
    "@SECRET_MANIFEST@": f"{root}/manifests/secretspec.toml",
    "@METADATA@": f"{root}/manifests/metadata.toml",
    "@APPLY_SECRET_REF@": "sec_00000000000000000001",
    "@ROLLBACK_SECRET_REF@": "sec_00000000000000000002",
    "@UPDATE_SECRET_REF@": "sec_00000000000000000003",
    "@APPLY_SECRET_NAME@": "PHAROS_APPLY_INSPR397_TARGET",
    "@ROLLBACK_SECRET_NAME@": "PHAROS_ROLLBACK_INSPR397_TARGET",
    "@UPDATE_SECRET_NAME@": "PHAROS_UPDATE_INSPR397_TARGET",
}
text = Path(source).read_text()
for old, new in replacements.items():
    text = text.replace(old, new)
if re.search(r"@[A-Z][A-Z0-9_]*@", text):
    raise SystemExit("unresolved review-script placeholder")
Path(output).write_text(text)
PY
  chmod +x "$output"
}

render_review "$test_root/review-configured" inspr "$test_root/state/role-bindings"
env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_CALL_LOG="$call_log" \
  "$test_root/review-configured" update NIX-490 >"$test_root/review.out"
grep -Fxq $'use\trun\tpreflight\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-operator' "$call_log"
grep -Fxq $'admin\tapprove\tissue\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-approver' "$call_log"
grep -Fxq $'admin\tapprove\tpermit\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-approver' "$call_log"
grep -Fxq $'use\trun\t--profile\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-operator' "$call_log"
[ "$(wc -l <"$call_log" | tr -d ' ')" -eq 4 ]
grep -Fq 'host=inspr397-target action=update status=completed ticket=NIX-490' "$test_root/review.out"

render_review "$test_root/review-unconfigured" '' ''
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_CALL_LOG="$call_log" \
  "$test_root/review-unconfigured" update NIX-490 >"$test_root/unconfigured.out" 2>"$test_root/unconfigured.err"; then
  echo 'unconfigured guarded deploy unexpectedly reached Janus' >&2
  exit 1
fi
grep -Fq 'stage=preflight failure_gate=preflight value_returned=false' "$test_root/unconfigured.err"

backup_line=$(grep -n "phase='backup'" "$apply" | cut -d: -f1)
switch_line=$(grep -n "phase='switch'" "$apply" | cut -d: -f1)
[ "$backup_line" -lt "$switch_line" ]
# shellcheck disable=SC2016
grep -Fq '[ "${#changed_paths[@]}" -eq 1 ]' "$apply"
# shellcheck disable=SC2016
grep -Fq '[ "${changed_paths[0]}" = "$PREFERENCES_PATH" ]' "$apply"
# shellcheck disable=SC2016
grep -Fq 'del(.hosts[$host])' "$apply"
# shellcheck disable=SC2016
grep -Fq 'zfs snapshot -r "$snapshot"' "$apply"
grep -Fq 'snapshot_count' "$apply"
grep -Fq 'switch-to-configuration' "$apply"
grep -Fq 'switch-to-configuration' "$rollback"
# shellcheck disable=SC2016
grep -Fq 'docker cp "$BEACON_CONTAINER:/etc/pharos/host-preferences.json"' "$apply"
# shellcheck disable=SC2016
grep -Fq 'docker cp "$HOSTDASH_CONTAINER:/usr/share/nginx/html/manifest.json"' "$apply"
grep -Fq 'restart_and_verify_runtime automatic-rollback' "$apply"
grep -Fq 'restart_and_verify_runtime automatic-recovery' "$rollback"

grep -Fq 'PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json' "$host_compose"
grep -Fq '/run/pharos-preferences:/etc/pharos:ro' "$host_compose"
if grep -Fq '/etc/pharos/host-preferences.json:/etc/pharos/host-preferences.json' "$host_compose"; then
  echo 'generation-pinning Pharos preferences file mount found' >&2
  exit 1
fi
grep -Fq 'environment.etc."pharos/host-preferences.json".source = ./pharos-host-preferences.json;' \
  "$repo_root/modules/common.nix"
grep -Fq 'system.activationScripts.pharosHostPreferences' "$repo_root/modules/common.nix"
grep -Fq \
  'install -m 0644 /etc/pharos/host-preferences.json /run/pharos-preferences/.host-preferences.json.tmp' \
  "$repo_root/modules/common.nix"
grep -Fq \
  'mv -f /run/pharos-preferences/.host-preferences.json.tmp /run/pharos-preferences/host-preferences.json' \
  "$repo_root/modules/common.nix"

if grep -ERq 'git reset|git clean|rm -rf|docker compose (down|restart|rm)' \
  "$repo_root/modules/pharos-guarded-deploy"; then
  echo 'unsafe broad operation found in guarded deploy module' >&2
  exit 1
fi
if grep -ERq '^[[:space:]]*eval[[:space:]]' "$repo_root/modules/pharos-guarded-deploy"; then
  echo 'shell eval found in guarded deploy module' >&2
  exit 1
fi

echo 'pharos_guarded_deploy=passed'
