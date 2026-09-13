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
operation_reference="$repo_root/modules/pharos-guarded-deploy/operation-reference.sh"
host_config="$repo_root/hosts/hsb8/configuration.nix"
host_compose="$repo_root/hosts/hsb8/docker/compose-spec.nix"

bash -n "$apply" "$rollback" "$bootstrap" "$bootstrap_roles" "$review" "$system_update" "$action_agent" "$operation_reference"

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
reference_log="$test_root/references.tsv"

cat >"$test_root/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = '-u' ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
EOF
cat >"$test_root/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "${TEST_NOW_EPOCH:-}" ] && [ "$#" -eq 2 ] && [ "$1" = '-u' ] && [ "$2" = '+%s' ]; then
  printf '%s\n' "$TEST_NOW_EPOCH"
else
  /bin/date "$@"
fi
EOF
cat >"$test_root/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = '-c' ]
case "$2" in
'%u:%g') printf '0:0\n' ;;
'%a') python3 - "$3" <<'PY'
import os
import stat
import sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
PY
;;
'%h') python3 - "$3" <<'PY'
import os
import sys
print(os.stat(sys.argv[1]).st_nlink)
PY
;;
'%s') python3 - "$3" <<'PY'
import os
import sys
print(os.stat(sys.argv[1]).st_size)
PY
;;
'%d:%i') python3 - "$3" <<'PY'
import os
import sys
value = os.stat(sys.argv[1])
print(f"{value.st_dev}:{value.st_ino}")
PY
;;
*) exit 64 ;;
esac
EOF
cat >"$test_root/bin/operation-reference" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$TEST_REFERENCE_LOG"
printf '%s/reference-%s.json\n' "$TEST_REFERENCE_ROOT" "$2"
EOF
cat >"$test_root/bin/janusd-use" <<'EOF'
#!/usr/bin/env bash
set -eu
for name in JANUS_SCOPE_ORGANIZATION JANUS_SCOPE_PROJECT JANUS_SCOPE_REPOSITORY JANUS_SCOPE_ENVIRONMENT JANUS_ROLE_AUTHORIZATION_MODE JANUS_ROLE_BINDINGS_ROOT JANUS_ROLE_AUDIT_FILE JANUS_RELEASE_EXECUTOR; do
  [ -n "${!name:-}" ] || exit 64
done
[ -z "${JANUS_ADMIN_EXECUTOR+x}" ] || exit 66
if [ "$1" = run ] && [ "${2:-}" = preflight ]; then
  [ -z "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE+x}" ] || exit 67
else
  [ -n "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE:-}" ] || exit 68
fi
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
case "${1:-} ${2:-}" in
'approve issue') [ -n "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE:-}" ] || exit 67 ;;
'approve permit') [ -z "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE+x}" ] || exit 68 ;;
esac
printf 'admin\t%s\t%s\t%s/%s/%s/%s\t%s\t%s\n' "$1" "${2:-}" \
  "$JANUS_SCOPE_ORGANIZATION" "$JANUS_SCOPE_PROJECT" "$JANUS_SCOPE_REPOSITORY" "$JANUS_SCOPE_ENVIRONMENT" \
  "$JANUS_ROLE_AUTHORIZATION_MODE" "$JANUS_RELEASE_EXECUTOR" >>"$TEST_CALL_LOG"
case "${1:-} ${2:-}" in
'approve issue') printf 'approval_id=appr_test\n' ;;
'approve permit') printf 'permit_id=use_test\n' ;;
*) exit 65 ;;
esac
EOF
chmod +x "$test_root/bin/id" "$test_root/bin/date" "$test_root/bin/stat" "$test_root/bin/operation-reference" \
  "$test_root/bin/janusd-use" "$test_root/bin/janusd-admin"
chmod 0700 "$test_root/state"

jq -n '{schema:"inspr.pharos.host-action-lease.v1",version:1,id:"lease-491",host:"inspr397-target",ticket:"NIX-490",phase:"review"}' \
  >"$test_root/state/active-agent-request.json"
chmod 0600 "$test_root/state/active-agent-request.json"

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
    "@OPERATION_REFERENCE_HELPER@": f"{root}/bin/operation-reference",
    "@ACTION_REQUEST_FILE@": f"{root}/state/active-agent-request.json",
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
  TEST_REFERENCE_LOG="$reference_log" \
  TEST_REFERENCE_ROOT="$test_root" \
  "$test_root/review-configured" update NIX-490 >"$test_root/review.out"
grep -Fxq $'use\trun\tpreflight\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-operator' "$call_log"
grep -Fxq $'admin\tapprove\tissue\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-approver' "$call_log"
grep -Fxq $'admin\tapprove\tpermit\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-approver' "$call_log"
grep -Fxq $'use\trun\t--profile\tinspr/pharos/inspr397-target/lab\tenforced\tinspr397-operator' "$call_log"
[ "$(wc -l <"$call_log" | tr -d ' ')" -eq 4 ]
[ "$(wc -l <"$reference_log" | tr -d ' ')" -eq 2 ]
grep -Fxq 'action approval update NIX-490 lease-491 review inspr397-target' "$reference_log"
grep -Fxq 'action execute update NIX-490 lease-491 review inspr397-target' "$reference_log"
grep -Fq 'host=inspr397-target action=update status=completed ticket=NIX-490' "$test_root/review.out"

render_review "$test_root/review-unconfigured" '' ''
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_CALL_LOG="$call_log" \
  TEST_REFERENCE_LOG="$reference_log" \
  TEST_REFERENCE_ROOT="$test_root" \
  "$test_root/review-unconfigured" update NIX-490 >"$test_root/unconfigured.out" 2>"$test_root/unconfigured.err"; then
  echo 'unconfigured guarded deploy unexpectedly reached Janus' >&2
  exit 1
fi
grep -Fq 'stage=preflight failure_gate=preflight value_returned=false' "$test_root/unconfigured.err"

cp "$test_root/state/active-agent-request.json" "$test_root/state/active-agent-request.valid.json"
jq '.ticket = "NIX-999"' "$test_root/state/active-agent-request.valid.json" \
  >"$test_root/state/active-agent-request.json"
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_CALL_LOG="$call_log" \
  TEST_REFERENCE_LOG="$reference_log" \
  TEST_REFERENCE_ROOT="$test_root" \
  "$test_root/review-configured" update NIX-490 >"$test_root/mismatch.out" 2>"$test_root/mismatch.err"; then
  echo 'mismatched protected lease unexpectedly reached Janus' >&2
  exit 1
fi
grep -Fq 'stage=input failure_gate=input value_returned=false' "$test_root/mismatch.err"

reference_root="$test_root/operation-references"
mkdir -p "$reference_root/incoming/actions/lease-491/review/update" "$reference_root/consumed"
find "$reference_root" -type d -exec chmod 0700 {} +
rendered_reference_helper="$test_root/operation-reference-helper"
python3 - "$operation_reference" "$rendered_reference_helper" "$reference_root" <<'PY'
from pathlib import Path
import re
import sys

source, output, root = sys.argv[1:]
replacements = {
    "@OPERATION_REFERENCE_ROOT@": root,
    "@OPERATION_SCOPE_REF@": "scp_595bd0a954b7cd1564068bceae2d3be518d5a5b0",
    "@OPERATION_DOMAIN_SERVICE@": "inspr397-guarded-deployment",
    "@OPERATION_AUDIENCE_FINGERPRINT@": "sha256:2aa4098811b85d84c04fa0cefad49f902a9b5af37b1e50bcd097e5c4af4d335e",
    "@OPERATION_RELEASE_DIGEST@": "sha256:0c4fe7bd5c025fd5c78e11052b4202f9c9fbcd9f263332436868c4780d3af560",
}
text = Path(source).read_text()
for old, new in replacements.items():
    text = text.replace(old, new)
if re.search(r"@[A-Z][A-Z0-9_]*@", text):
    raise SystemExit("unresolved operation-reference placeholder")
Path(output).write_text(text)
PY
chmod +x "$rendered_reference_helper"

make_operation_reference() {
  local path=$1
  local lineage=$2
  local duty=$3
  local nonce=$4
  local expiry_offset=${5:-240}
  python3 - "$path" "$lineage" "$duty" "$nonce" "$expiry_offset" <<'PY'
import hashlib
import json
from pathlib import Path
import struct
import sys
import time

path, lineage, duty, nonce, expiry_offset = sys.argv[1:]
now = int(time.time())
issued = now if int(expiry_offset) > 0 else now - 301
expires = now + int(expiry_offset)
hasher = hashlib.sha256()
for field in ("janus-operation-ref-v1", "use_request", lineage):
    raw = field.encode()
    hasher.update(struct.pack(">Q", len(raw)))
    hasher.update(raw)
value = {
    "schema_version": 1,
    "domain_service": "inspr397-guarded-deployment",
    "operation_ref": "opr_" + hasher.hexdigest()[:32],
    "scope_ref": "scp_595bd0a954b7cd1564068bceae2d3be518d5a5b0",
    "conflict_domain": "use_request",
    "duty": duty,
    "state_revision": 7,
    "policy_revision": "guarded-policy-v1",
    "issued_at_unix_secs": issued,
    "expires_at_unix_secs": expires,
    "nonce_ref": nonce,
    "audience_fingerprint": "sha256:2aa4098811b85d84c04fa0cefad49f902a9b5af37b1e50bcd097e5c4af4d335e",
    "release_digest": "sha256:0c4fe7bd5c025fd5c78e11052b4202f9c9fbcd9f263332436868c4780d3af560",
    "signature": "a" * 128,
}
Path(path).write_text(json.dumps(value, separators=(",", ":")) + "\n")
Path(path).chmod(0o600)
PY
}

action_lineage='inspr397-guarded-action-v1|id=lease-491|host=inspr397-target|ticket=NIX-490|phase=review|action=update'
approval_input="$reference_root/incoming/actions/lease-491/review/update/approval.json"
# Real outputs from janusd-operation-ref-issuer 2bccc043; its retained public
# verifier proves these signatures, and the disposable signing seed was removed.
printf '%s' '{"schema_version":1,"domain_service":"inspr397-guarded-deployment","operation_ref":"opr_7b28e39c19b4204fa0486ee2823738a1","scope_ref":"scp_595bd0a954b7cd1564068bceae2d3be518d5a5b0","conflict_domain":"use_request","duty":"approve_use","state_revision":7,"policy_revision":"guarded-policy-v1","issued_at_unix_secs":1789310001,"expires_at_unix_secs":1789310241,"nonce_ref":"nce_ae2bf0ee7b8f54d6fdabe9e3","audience_fingerprint":"sha256:2aa4098811b85d84c04fa0cefad49f902a9b5af37b1e50bcd097e5c4af4d335e","release_digest":"sha256:0c4fe7bd5c025fd5c78e11052b4202f9c9fbcd9f263332436868c4780d3af560","signature":"770ce01fb44e14fd6f62fcbaf4ab5c1256284a85a8224aa0a2ae04adf079cb97ccdeb590846a771558127e81ae30650618ff56dc332fbab5d0f05170e4db4605"}' >"$approval_input"
chmod 0600 "$approval_input"
claimed_reference=$(env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_NOW_EPOCH=1789310002 \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target)
[ "$claimed_reference" = "$reference_root/consumed/nce_ae2bf0ee7b8f54d6fdabe9e3/reference.json" ]
[ -f "$claimed_reference" ]
[ ! -e "$approval_input" ]

if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target \
  >"$test_root/missing.out" 2>"$test_root/missing.err"; then
  echo 'missing operation reference was accepted' >&2
  exit 1
fi
grep -Fq 'reason=reference_missing value_returned=false' "$test_root/missing.err"

cp "$claimed_reference" "$approval_input"
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_NOW_EPOCH=1789310002 \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target \
  >"$test_root/reused.out" 2>"$test_root/reused.err"; then
  echo 'consumed operation reference nonce was accepted again' >&2
  exit 1
fi
grep -Fq 'reason=reference_reused value_returned=false' "$test_root/reused.err"

make_operation_reference "$approval_input" \
  'inspr397-guarded-action-v1|id=lease-491|host=inspr397-target|ticket=NIX-490|phase=apply|action=update' \
  approve_use nce_222222222222222222222222
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target \
  >"$test_root/mismatched-reference.out" 2>"$test_root/mismatched-reference.err"; then
  echo 'operation reference for another protected lease phase was accepted' >&2
  exit 1
fi
grep -Fq 'reason=reference_context_invalid value_returned=false' "$test_root/mismatched-reference.err"
[ -f "$approval_input" ]

make_operation_reference "$approval_input" "$action_lineage" execute_use nce_222222222222222222222222
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target \
  >"$test_root/wrong-step.out" 2>"$test_root/wrong-step.err"; then
  echo 'execute operation reference was accepted for approval step' >&2
  exit 1
fi
grep -Fq 'reason=reference_context_invalid value_returned=false' "$test_root/wrong-step.err"

chmod 0644 "$approval_input"
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target \
  >"$test_root/mode.out" 2>"$test_root/mode.err"; then
  echo 'wrong-mode operation reference was accepted' >&2
  exit 1
fi
grep -Fq 'reason=reference_mode_invalid value_returned=false' "$test_root/mode.err"
chmod 0600 "$approval_input"
ln "$approval_input" "$test_root/reference-hardlink.json"
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action approval update NIX-490 lease-491 review inspr397-target \
  >"$test_root/link.out" 2>"$test_root/link.err"; then
  echo 'hard-linked operation reference was accepted' >&2
  exit 1
fi
grep -Fq 'reason=reference_link_invalid value_returned=false' "$test_root/link.err"
unlink "$test_root/reference-hardlink.json"

execute_input="$reference_root/incoming/actions/lease-491/review/update/execute.json"
printf '%s' '{"schema_version":1,"domain_service":"inspr397-guarded-deployment","operation_ref":"opr_7b28e39c19b4204fa0486ee2823738a1","scope_ref":"scp_595bd0a954b7cd1564068bceae2d3be518d5a5b0","conflict_domain":"use_request","duty":"execute_use","state_revision":7,"policy_revision":"guarded-policy-v1","issued_at_unix_secs":1789310001,"expires_at_unix_secs":1789310241,"nonce_ref":"nce_2ab8143e04b1eafca8f399cd","audience_fingerprint":"sha256:2aa4098811b85d84c04fa0cefad49f902a9b5af37b1e50bcd097e5c4af4d335e","release_digest":"sha256:0c4fe7bd5c025fd5c78e11052b4202f9c9fbcd9f263332436868c4780d3af560","signature":"72edbb84b54a0234a83bbe3d8c3816f019ec9e4f1d88475e06a490f0a32448789ab067ad410a78d1f8e94b44249e2d60556fed6784bf5cda2e4fae4bf89d6606"}' >"$execute_input"
chmod 0600 "$execute_input"
claimed_execute=$(env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_NOW_EPOCH=1789310002 \
  "$rendered_reference_helper" action execute update NIX-490 lease-491 review inspr397-target)
[ "$claimed_execute" = "$reference_root/consumed/nce_2ab8143e04b1eafca8f399cd/reference.json" ]
[ -f "$claimed_execute" ]

make_operation_reference "$execute_input" "$action_lineage" execute_use nce_333333333333333333333333 -1
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action execute update NIX-490 lease-491 review inspr397-target \
  >"$test_root/stale.out" 2>"$test_root/stale.err"; then
  echo 'stale operation reference was accepted' >&2
  exit 1
fi
grep -Fq 'reason=reference_context_invalid value_returned=false' "$test_root/stale.err"

mv "$execute_input" "$test_root/reference-target.json"
ln -s "$test_root/reference-target.json" "$execute_input"
if env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  "$rendered_reference_helper" action execute update NIX-490 lease-491 review inspr397-target \
  >"$test_root/symlink.out" 2>"$test_root/symlink.err"; then
  echo 'symlinked operation reference was accepted' >&2
  exit 1
fi
grep -Fq 'reason=reference_missing value_returned=false' "$test_root/symlink.err"

mkdir -p "$test_root/state/role-bindings"
: >"$test_root/state/role-audit.jsonl"
chmod 0700 "$test_root/state/role-bindings"
chmod 0600 "$test_root/state/role-audit.jsonl"
cat >"$test_root/bin/janusd-admin-roles" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\t%s\t%s\n' "$1" "${2:-}" "${JANUS_RELEASE_EXECUTOR:-}" \
  "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE:-}" >>"$TEST_ROLE_CALL_LOG"
case "${1:-} ${2:-}" in
'role-binding issue')
  [ -n "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE:-}" ] || exit 67
  role=''
  bootstrap=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --role) role=$2; shift 2 ;;
    --bootstrap) bootstrap=true; shift ;;
    *) shift ;;
    esac
  done
  if [ "$bootstrap" = true ]; then
    [ "${JANUS_ROLE_BOOTSTRAP_ACK:-}" = 'bootstrap-role-authorization' ] || exit 70
    jq -n '{binding_id:"rbd_bootstrap",scope_ref:"scp_595bd0a954b7cd1564068bceae2d3be518d5a5b0",role:"security_admin",source_kind:"unsafe_bootstrap",status:"active",value_returned:false}'
  else
    jq -n --arg role "$role" '{role:$role,source_kind:"local_reviewed",status:"active",value_returned:false}'
  fi
  ;;
'role-binding revoke')
  [ -z "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE+x}" ] || exit 68
  jq -n '{value_returned:false}'
  ;;
'role-binding list')
  [ -z "${JANUS_RUNTIME_OPERATION_REFERENCE_FILE+x}" ] || exit 69
  jq -n '{value_returned:false,bindings:[
    {source_kind:"unsafe_bootstrap",status:"revoked",role:"security_admin"},
    {source_kind:"local_reviewed",status:"active",role:"security_admin"},
    {source_kind:"local_reviewed",status:"active",role:"operator"},
    {source_kind:"local_reviewed",status:"active",role:"approver"}
  ]}'
  ;;
*) exit 65 ;;
esac
EOF
chmod +x "$test_root/bin/janusd-admin-roles"

rendered_role_bootstrap="$test_root/role-bootstrap"
python3 - "$bootstrap_roles" "$rendered_role_bootstrap" "$test_root" <<'PY'
from pathlib import Path
import re
import sys

source, output, root = sys.argv[1:]
replacements = {
    "@JANUSD_ADMIN@": f"{root}/bin/janusd-admin-roles",
    "@SCOPE_ORGANIZATION@": "inspr",
    "@SCOPE_PROJECT@": "pharos",
    "@SCOPE_REPOSITORY@": "inspr397-target",
    "@SCOPE_ENVIRONMENT@": "lab",
    "@ROLE_BINDINGS_ROOT@": f"{root}/state/role-bindings",
    "@ROLE_AUDIT_FILE@": f"{root}/state/role-audit.jsonl",
    "@ROLE_POLICY_FILE@": "",
    "@BOOTSTRAP_PRINCIPAL@": "inspr397-lab-bootstrap",
    "@SECURITY_ADMIN_PRINCIPAL@": "inspr397-lab-security-admin",
    "@USE_PRINCIPAL@": "inspr397-lab-guarded-use",
    "@ADMIN_PRINCIPAL@": "inspr397-lab-guarded-approval",
    "@SOURCE_REFERENCE@": "INSPR-397",
    "@BINDING_TTL_SECONDS@": "86400",
    "@OPERATION_REFERENCE_HELPER@": f"{root}/bin/operation-reference",
}
text = Path(source).read_text()
for old, new in replacements.items():
    text = text.replace(old, new)
if re.search(r"@[A-Z][A-Z0-9_]*@", text):
    raise SystemExit("unresolved role-bootstrap placeholder")
Path(output).write_text(text)
PY
chmod +x "$rendered_role_bootstrap"
role_call_log="$test_root/role-calls.tsv"
: >"$reference_log"
env -i \
  PATH="$test_root/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_REFERENCE_LOG="$reference_log" \
  TEST_REFERENCE_ROOT="$test_root" \
  TEST_ROLE_CALL_LOG="$role_call_log" \
  "$rendered_role_bootstrap" >"$test_root/role-bootstrap.out"
[ "$(wc -l <"$reference_log" | tr -d ' ')" -eq 4 ]
grep -Fxq 'bootstrap bootstrap-security-admin INSPR-397' "$reference_log"
grep -Fxq 'bootstrap reviewed-security-admin INSPR-397' "$reference_log"
grep -Fxq 'bootstrap reviewed-operator INSPR-397' "$reference_log"
grep -Fxq 'bootstrap reviewed-approver INSPR-397' "$reference_log"
[ "$(grep -c $'^role-binding\tissue\t.*reference-' "$role_call_log")" -eq 4 ]
[ "$(wc -l <"$role_call_log" | tr -d ' ')" -eq 6 ]

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
