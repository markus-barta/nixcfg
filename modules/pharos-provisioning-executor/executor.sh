#!/usr/bin/env bash
set -Eeuo pipefail

readonly OWNER='@OWNER@'
readonly PHAROS_AGENT_URL='@PHAROS_AGENT_URL@'
readonly PHAROS_PUBLIC_URL='@PHAROS_PUBLIC_URL@'
readonly STATE_DIR='@STATE_DIR@'
readonly RUNTIME_DIR='@RUNTIME_DIR@'
readonly REPO_PATH='@REPO_PATH@'
readonly IDENTITY_FILE='@IDENTITY_FILE@'
readonly SSH_KEY_REF='@SSH_KEY_REF@'
readonly BOOTSTRAP_TEMPLATE='@BOOTSTRAP_TEMPLATE@'
readonly JANUS_HELPER='@JANUS_HELPER@'
readonly PENDING_RESULT="$STATE_DIR/pending-result.json"

[ "$(id -u)" -eq 0 ]
[[ "$OWNER" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
[[ "$PHAROS_AGENT_URL" =~ ^http://[0-9.]+:[0-9]+$ ]]
[[ "$PHAROS_PUBLIC_URL" =~ ^https://[^[:space:]]+$ ]]
[[ "$STATE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$RUNTIME_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$REPO_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$IDENTITY_FILE" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$SSH_KEY_REF" =~ ^[A-Za-z0-9][A-Za-z0-9_.@+-]{0,127}$ ]]
[[ -n "${PHAROS_TOKEN:-}" ]]
[[ "$PHAROS_TOKEN" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]

mkdir -p "$STATE_DIR" "$RUNTIME_DIR"
chmod 0700 "$STATE_DIR" "$RUNTIME_DIR"
exec 9>"$STATE_DIR/executor.lock"
flock -n 9 || exit 0

run_dir=$(mktemp -d "$RUNTIME_DIR/.run.XXXXXX")
chmod 0700 "$run_dir"
auth_config="$run_dir/curl.conf"
claim_request="$run_dir/claim.json"
claim_response="$run_dir/claim-response.json"
result_request="$run_dir/result.json"
result_response="$run_dir/result-response.json"

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
	find "$run_dir" -type f -exec shred -u {} + 2>/dev/null || true
	find "$run_dir" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT

printf 'header = "Authorization: Bearer %s"\n' "$PHAROS_TOKEN" >"$auth_config"
chmod 0600 "$auth_config"
unset PHAROS_TOKEN

curl_json() {
	local method=$1
	local path=$2
	local body=$3
	local response=$4

	curl --silent --show-error \
		--connect-timeout 10 \
		--max-time 30 \
		--config "$auth_config" \
		--request "$method" \
		--header 'Content-Type: application/json' \
		--data-binary "@$body" \
		--output "$response" \
		--write-out '%{http_code}' \
		"$PHAROS_AGENT_URL$path"
}

valid_pending_result() {
	jq -e --arg owner "$OWNER" '
    .schema == "inspr.pharos.provisioning-executor-result.v1"
    and .version == 1
    and .owner == $owner
    and .ticket == "PHAROS-175"
    and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,159}$"))
    and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.action == "bootstrap" or .action == "retire")
    and (.credential_created | type == "boolean")
    and (
      (.outcome == "succeeded" and .reason == null
        and ((.action == "bootstrap" and .credential_created == true)
          or (.action == "retire" and .credential_created == false)))
      or
      ((.outcome == "failed" or .outcome == "uncertain") and (
        .reason == "checkout_not_ready"
        or .reason == "janus_unavailable"
        or .reason == "janus_rejected"
        or .reason == "ssh_identity_unavailable"
        or .reason == "ssh_unreachable"
        or .reason == "host_key_mismatch"
        or .reason == "bootstrap_failed"
        or .reason == "result_contract_invalid"
        or .reason == "uncertain_execution"
      ))
    )
    and (keys | sort == ["action","credential_created","host","id","outcome","owner","reason","schema","ticket","version"])
  ' "$PENDING_RESULT" >/dev/null 2>&1
}

report_pending_result() {
	local action_id outcome result_code

	[ -f "$PENDING_RESULT" ] && [ ! -L "$PENDING_RESULT" ] || {
		printf 'pharos_provisioning_executor=blocked reason=invalid_pending_result\n' >&2
		return 1
	}
	valid_pending_result || {
		printf 'pharos_provisioning_executor=blocked reason=invalid_pending_result\n' >&2
		return 1
	}
	action_id=$(jq -r '.id' "$PENDING_RESULT")
	outcome=$(jq -r '.outcome' "$PENDING_RESULT")
	jq '{owner,host,action,outcome,credential_created} + if .reason == null then {} else {reason} end' \
		"$PENDING_RESULT" >"$result_request"
	if ! result_code=$(curl_json POST "/agent/provisioning/$action_id/result" \
		"$result_request" "$result_response"); then
		printf 'pharos_provisioning_executor=deferred reason=result_unreachable\n' >&2
		return 0
	fi
	if [ "$result_code" != 204 ]; then
		printf 'pharos_provisioning_executor=deferred reason=result_rejected status=%s\n' \
			"$result_code" >&2
		return 0
	fi
	shred -u "$PENDING_RESULT"
	printf 'pharos_provisioning_executor=reported outcome=%s\n' "$outcome"
}

if [ -e "$PENDING_RESULT" ]; then
	report_pending_result
	exit $?
fi

jq -n --arg owner "$OWNER" '{owner:$owner}' >"$claim_request"
if ! claim_code=$(curl_json POST /agent/provisioning/claim "$claim_request" "$claim_response"); then
	printf 'pharos_provisioning_executor=deferred reason=claim_unreachable\n' >&2
	exit 0
fi
case "$claim_code" in
204)
	printf 'pharos_provisioning_executor=idle\n'
	exit 0
	;;
200) ;;
*)
	printf 'pharos_provisioning_executor=deferred reason=claim_rejected status=%s\n' \
		"$claim_code" >&2
	exit 0
	;;
esac

now=$(date +%s)
if ! jq -e \
	--arg owner "$OWNER" \
	--arg ssh_key_ref "$SSH_KEY_REF" \
	--argjson now "$now" '
  .schema == "inspr.pharos.provisioning-agent-lease.v1"
  and .version == 1
  and .ticket == "PHAROS-175"
  and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,159}$"))
  and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
  and .host != $owner
  and (.credential_ref | type == "string" and test("^sec_[0-9a-f]{20}$"))
  and (.provider_id | type == "string" and test("^[1-9][0-9]{0,19}$"))
  and (.lease_until | type == "number" and floor == . and . > $now and . <= ($now + 3900))
  and .ssh_key_ref == $ssh_key_ref
  and (.role | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$"))
  and (.heartbeat_interval_secs | type == "number" and floor == . and . >= 10 and . <= 3600)
  and (
    (.action == "bootstrap"
      and (.ssh_host | type == "string" and length >= 2 and length <= 64)
      and .ssh_port == 22
      and (.host_key_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$"))
      and (keys | sort == ["action","credential_ref","heartbeat_interval_secs","host","host_key_fingerprint","id","lease_until","provider_id","role","schema","ssh_host","ssh_key_ref","ssh_port","ticket","version"]))
    or
    (.action == "retire"
      and (keys | sort == ["action","credential_ref","heartbeat_interval_secs","host","id","lease_until","provider_id","role","schema","ssh_key_ref","ticket","version"]))
  )
' "$claim_response" >/dev/null; then
	printf 'pharos_provisioning_executor=blocked reason=invalid_lease\n' >&2
	exit 1
fi

action_id=$(jq -r '.id' "$claim_response")
target_host=$(jq -r '.host' "$claim_response")
action=$(jq -r '.action' "$claim_response")
credential_ref=$(jq -r '.credential_ref' "$claim_response")
lease_until=$(jq -r '.lease_until' "$claim_response")
credential_created=false
outcome=failed
reason=checkout_not_ready

save_result() {
	local pending_tmp
	pending_tmp=$(mktemp "$STATE_DIR/.pending-result.XXXXXX")
	jq -n \
		--arg id "$action_id" \
		--arg owner "$OWNER" \
		--arg host "$target_host" \
		--arg action "$action" \
		--arg outcome "$outcome" \
		--arg reason "$reason" \
		--argjson credential_created "$credential_created" '
    {
      schema:"inspr.pharos.provisioning-executor-result.v1",
      version:1,
      id:$id,
      owner:$owner,
      host:$host,
      ticket:"PHAROS-175",
      action:$action,
      outcome:$outcome,
      credential_created:$credential_created,
      reason:(if $reason == "" then null else $reason end)
    }' >"$pending_tmp"
	chmod 0600 "$pending_tmp"
	mv "$pending_tmp" "$PENDING_RESULT"
}

finish() {
	save_result
	if ! report_pending_result; then
		exit 1
	fi
	exit 0
}

# Invoked by the ERR trap after a lease has been claimed.
# shellcheck disable=SC2329
unexpected_failure() {
	local failure_status=$?
	trap - ERR
	outcome=uncertain
	reason=uncertain_execution
	if [ ! -e "$PENDING_RESULT" ] && ! save_result; then
		printf 'pharos_provisioning_executor=blocked reason=result_persistence_failed\n' >&2
		exit "$failure_status"
	fi
	report_pending_result || true
	exit "$failure_status"
}
trap unexpected_failure ERR

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$REPO_PATH"
if ! git -C "$REPO_PATH" fetch --quiet --prune origin \
	>"$run_dir/fetch.out" 2>"$run_dir/fetch.err"; then
	finish
fi
if [ "$(git -C "$REPO_PATH" branch --show-current)" != main ] ||
	[ -n "$(git -C "$REPO_PATH" status --porcelain=v1 --untracked-files=all)" ] ||
	[ "$(git -C "$REPO_PATH" rev-parse HEAD)" != "$(git -C "$REPO_PATH" rev-parse origin/main)" ] ||
	[ ! -x "$JANUS_HELPER" ]; then
	finish
fi

janus_output="$run_dir/janus.out"
janus_error="$run_dir/janus.err"
if [ "$action" = retire ]; then
	if "$JANUS_HELPER" retire "$action_id" "$target_host" "$credential_ref" \
		>"$janus_output" 2>"$janus_error"; then
		if grep -Fx 'janus_managed_beacon=retired value_returned=false credential_created=false' \
			"$janus_output" >/dev/null; then
			outcome=succeeded
			reason=''
		else
			outcome=uncertain
			reason=result_contract_invalid
		fi
	else
		safe_failure=$(grep -E \
			'^janus_managed_beacon=failed reason=[a-z_]+ value_returned=false credential_created=(true|false)$' \
			"$janus_error" | tail -n1 || true)
		if [[ "$safe_failure" =~ credential_created=(true|false) ]]; then
			credential_created=${BASH_REMATCH[1]}
		fi
		if [[ "$safe_failure" =~ reason=([a-z_]+) ]]; then
			case "${BASH_REMATCH[1]}" in
			checkout_not_ready | janus_unavailable | janus_rejected | result_contract_invalid)
				reason=${BASH_REMATCH[1]}
				;;
			uncertain_execution)
				outcome=uncertain
				reason=uncertain_execution
				;;
			*)
				outcome=uncertain
				reason=result_contract_invalid
				;;
			esac
		else
			outcome=uncertain
			reason=result_contract_invalid
		fi
	fi
	credential_created=false
	finish
fi

ssh_host=$(jq -r '.ssh_host' "$claim_response")
ssh_port=$(jq -r '.ssh_port' "$claim_response")
host_key_fingerprint=$(jq -r '.host_key_fingerprint' "$claim_response")
role=$(jq -r '.role' "$claim_response")
heartbeat_interval=$(jq -r '.heartbeat_interval_secs' "$claim_response")
python3 - "$ssh_host" <<'PY' >/dev/null 2>&1 || {
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if str(address) != sys.argv[1]:
    raise SystemExit(1)
PY
	reason=result_contract_invalid
	finish
}

identity_metadata=$(stat -Lc '%F %u %a' "$IDENTITY_FILE" 2>/dev/null || true)
if [ "$identity_metadata" != "regular file 0 600" ] && [ "$identity_metadata" != "regular file 0 400" ]; then
	reason=ssh_identity_unavailable
	finish
fi
[ ! -L "$IDENTITY_FILE" ] || {
	reason=ssh_identity_unavailable
	finish
}

public_key_file="$run_dir/executor.pub"
if ! ssh-keygen -y -P '' -f "$IDENTITY_FILE" >"$public_key_file" 2>"$run_dir/keygen.err"; then
	reason=ssh_identity_unavailable
	finish
fi
chmod 0600 "$public_key_file"
if ! grep -Eq '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}$' "$public_key_file"; then
	reason=ssh_identity_unavailable
	finish
fi

known_hosts="$run_dir/known_hosts"
if ! ssh-keyscan -T 10 -p "$ssh_port" -t ed25519 "$ssh_host" \
	>"$known_hosts" 2>"$run_dir/keyscan.err"; then
	reason=ssh_unreachable
	finish
fi
chmod 0600 "$known_hosts"
key_line_count=$(grep -c ' ssh-ed25519 ' "$known_hosts" || true)
if [ "$key_line_count" != 1 ]; then
	reason=host_key_mismatch
	finish
fi
observed_fingerprint=$(ssh-keygen -lf "$known_hosts" -E sha256 2>/dev/null | awk 'NR == 1 { print $2 }')
if [ "$observed_fingerprint" != "$host_key_fingerprint" ]; then
	reason=host_key_mismatch
	finish
fi

ssh_options=(
	-F /dev/null
	-i "$IDENTITY_FILE"
	-o IdentitiesOnly=yes
	-o BatchMode=yes
	-o "UserKnownHostsFile=$known_hosts"
	-o StrictHostKeyChecking=yes
	-o GlobalKnownHostsFile=/dev/null
	-o ConnectTimeout=10
	-p "$ssh_port"
	"root@$ssh_host"
)
authorized_keys="$run_dir/authorized_keys"
if ! ssh "${ssh_options[@]}" \
	'test -f /root/.ssh/authorized_keys && test ! -L /root/.ssh/authorized_keys && cat /root/.ssh/authorized_keys' \
	>"$authorized_keys" 2>"$run_dir/ssh.err"; then
	reason=ssh_unreachable
	finish
fi
local_key=$(awk 'NR == 1 { print $1 " " $2 }' "$public_key_file")
if ! awk -v expected="$local_key" '
  $1 == "ssh-ed25519" && ($1 " " $2) == expected { found = 1 }
  END { exit(found ? 0 : 1) }
' "$authorized_keys"; then
	reason=ssh_identity_unavailable
	finish
fi

remote_arch="$run_dir/arch"
remote_disks="$run_dir/disks.json"
if ! ssh "${ssh_options[@]}" 'uname -m' >"$remote_arch" 2>"$run_dir/arch.err" ||
	[ "$(tr -d '\r\n' <"$remote_arch")" != x86_64 ]; then
	reason=bootstrap_failed
	finish
fi
if ! ssh "${ssh_options[@]}" 'lsblk --json --bytes --output PATH,TYPE,RM,RO' \
	>"$remote_disks" 2>"$run_dir/disks.err"; then
	reason=ssh_unreachable
	finish
fi
if ! jq -e '
  (.blockdevices | type == "array")
  and ([.blockdevices[] | select(
    .type == "disk"
    and (.rm == false or .rm == 0)
    and (.ro == false or .ro == 0)
    and (.path | type == "string" and test("^/dev/[A-Za-z0-9._/-]+$"))
  )] | length) == 1
' "$remote_disks" >/dev/null; then
	reason=bootstrap_failed
	finish
fi
install_disk=$(jq -r '[.blockdevices[] | select(
  .type == "disk"
  and (.rm == false or .rm == 0)
  and (.ro == false or .ro == 0)
)] | .[0].path' "$remote_disks")
[[ "$install_disk" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || {
	reason=result_contract_invalid
	finish
}

bootstrap_dir="$run_dir/bootstrap"
extra_files="$run_dir/extra-files"
mkdir -p "$bootstrap_dir" "$extra_files"
cp -R "$BOOTSTRAP_TEMPLATE"/. "$bootstrap_dir"/
jq -n \
	--arg host "$target_host" \
	--arg role "$role" \
	--arg disk "$install_disk" \
	--arg pharos_url "$PHAROS_PUBLIC_URL" \
	--arg ssh_public_key "$local_key" \
	--argjson heartbeat_interval_secs "$heartbeat_interval" '
  {
    host:$host,
    role:$role,
    disk:$disk,
    pharos_url:$pharos_url,
    ssh_public_key:$ssh_public_key,
    heartbeat_interval_secs:$heartbeat_interval_secs
  }' >"$bootstrap_dir/runtime.json"
chmod 0600 "$bootstrap_dir/runtime.json"

if "$JANUS_HELPER" issue "$action_id" "$target_host" "$credential_ref" "$extra_files" \
	>"$janus_output" 2>"$janus_error"; then
	if ! grep -Fx 'janus_managed_beacon=issued value_returned=false credential_created=true' \
		"$janus_output" >/dev/null; then
		outcome=uncertain
		reason=result_contract_invalid
		credential_created=true
		finish
	fi
	credential_created=true
else
	safe_failure=$(grep -E \
		'^janus_managed_beacon=failed reason=[a-z_]+ value_returned=false credential_created=(true|false)$' \
		"$janus_error" | tail -n1 || true)
	if [[ "$safe_failure" =~ credential_created=(true|false) ]]; then
		credential_created=${BASH_REMATCH[1]}
	fi
	if [[ "$safe_failure" =~ reason=([a-z_]+) ]]; then
		case "${BASH_REMATCH[1]}" in
		checkout_not_ready | janus_unavailable | janus_rejected | result_contract_invalid)
			reason=${BASH_REMATCH[1]}
			;;
		uncertain_execution)
			outcome=uncertain
			reason=uncertain_execution
			;;
		*)
			outcome=uncertain
			reason=result_contract_invalid
			;;
		esac
	else
		outcome=uncertain
		reason=result_contract_invalid
	fi
	finish
fi

now=$(date +%s)
if [ "$lease_until" -le "$((now + 300))" ]; then
	reason=bootstrap_failed
	finish
fi

if ! timeout --signal=TERM --kill-after=30s 6600s \
	nixos-anywhere \
	--flake "path:${bootstrap_dir}#managed" \
	--target-host "root@$ssh_host" \
	-i "$IDENTITY_FILE" \
	--ssh-port "$ssh_port" \
	--ssh-option IdentitiesOnly=yes \
	--ssh-option BatchMode=yes \
	--ssh-option "UserKnownHostsFile=$known_hosts" \
	--ssh-option StrictHostKeyChecking=yes \
	--ssh-option GlobalKnownHostsFile=/dev/null \
	--ssh-option ConnectTimeout=10 \
	--copy-host-keys \
	--extra-files "$extra_files" \
	--build-on local \
	>"$run_dir/bootstrap.out" 2>"$run_dir/bootstrap.err"; then
	outcome=uncertain
	reason=bootstrap_failed
	finish
fi

verified=false
for _attempt in $(seq 1 12); do
	if ssh "${ssh_options[@]}" \
		'test -e /run/current-system && systemctl is-enabled --quiet podman-pharos-beacon.service && systemctl is-active --quiet podman-pharos-beacon.service' \
		>"$run_dir/verify.out" 2>"$run_dir/verify.err"; then
		verified=true
		break
	fi
	sleep 10
done
if [ "$verified" != true ]; then
	outcome=uncertain
	reason=uncertain_execution
	finish
fi

outcome=succeeded
reason=''
finish
