#!/usr/bin/env bash
set -euo pipefail

umask 077

host=${1-}
disposition=${2-}
successor=${3-}
request_id=${4-}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=${PHAROS_REMOVAL_REPO_ROOT:-$(cd -- "$script_dir/.." && pwd)}
compose_file=${PHAROS_REMOVAL_COMPOSE_FILE:-$repo_root/hosts/csb1/docker/docker-compose.yml}
preferences_file=${PHAROS_REMOVAL_PREFERENCES_FILE:-$repo_root/modules/pharos-host-preferences.json}
manifest_dir=${PHAROS_REMOVAL_MANIFEST_DIR:-$repo_root/hosts/csb1/docker/pharos/manifests}
retirements_file=${PHAROS_REMOVAL_RETIREMENTS_FILE:-$repo_root/hosts/csb1/docker/janus/pharos-production/retired-hosts.json}
output_file=${GITHUB_OUTPUT:-${PHAROS_REMOVAL_OUTPUT:-}}

fail() {
  printf 'pharos_host_removal=failed reason=%s\n' "$1" >&2
  exit 1
}

valid_host() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

valid_host "$host" || fail invalid_host
[[ "$disposition" == destroyed || "$disposition" == unmanaged || "$disposition" == rebuilt ]] || fail invalid_disposition
[[ "$request_id" =~ ^pharos-host-removal-${host}-[0-9]+-[0-9]+$ ]] || fail invalid_request_id

if [[ "$disposition" == rebuilt ]]; then
  valid_host "$successor" || fail invalid_successor
  [[ "$successor" != "$host" ]] || fail invalid_successor
else
  [[ -z "$successor" ]] || fail unexpected_successor
fi

for path in "$compose_file" "$preferences_file" "$manifest_dir" "$retirements_file"; do
  [[ -e "$path" ]] || fail missing_contract_file
done

if [[ ${PHAROS_REMOVAL_FIXTURE:-0} != 1 ]]; then
  [[ -d "$repo_root/.git" || -f "$repo_root/.git" ]] || fail not_nixcfg_checkout
  [[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || fail checkout_not_clean
fi

jq -e '
  .schema == "inspr.pharos.host-preferences.v1"
  and .version == 1
  and (.hosts | type == "object")
' "$preferences_file" >/dev/null || fail invalid_preferences_contract

jq -e '
  .schema == "inspr.pharos.janus-retirements.v1"
  and .version == 1
  and (.retirements | type == "array")
  and all(.retirements[];
    (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.disposition == "destroyed" or .disposition == "unmanaged" or .disposition == "rebuilt")
    and (.successor == null or (.successor | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")))
    and .credential_retirement_required == true
    and .server_deletion == false
    and ((keys | sort) == ["credential_retirement_required", "disposition", "host", "server_deletion", "successor"])
  )
' "$retirements_file" >/dev/null || fail invalid_retirements_contract

if jq -e --arg host "$host" '.retirements[] | select(.host == $host)' "$retirements_file" >/dev/null; then
  fail host_already_retired
fi

matching_manifests=()
while IFS= read -r candidate; do
  if jq -e --arg host "$host" '.host.name == $host' "$candidate" >/dev/null 2>&1; then
    matching_manifests+=("$candidate")
  fi
done < <(find "$manifest_dir" -maxdepth 1 -type f -name '*.json' -print)
[[ ${#matching_manifests[@]} -eq 1 ]] || fail declared_manifest_not_unique
manifest_file=${matching_manifests[0]}
manifest_name=$(basename -- "$manifest_file")

work_dir=$(mktemp -d)
cleanup() {
  rm -r "$work_dir"
}
trap cleanup EXIT

python3 - "$compose_file" "$manifest_name" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
target = "/manifests/" + sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
matches = []
updated = []

for line in lines:
    stripped = line.strip()
    prefix = "- PHAROS_MANIFEST_PATHS="
    if not stripped.startswith(prefix):
        updated.append(line)
        continue
    matches.append(line)
    paths = [item.strip() for item in stripped[len(prefix):].split(",") if item.strip()]
    if target not in paths:
        raise SystemExit("declared manifest is not present in PHAROS_MANIFEST_PATHS")
    remaining = [item for item in paths if item != target]
    if remaining:
        indent = line[: len(line) - len(line.lstrip())]
        updated.append(f"{indent}{prefix}{','.join(remaining)}\n")

if len(matches) != 1:
    raise SystemExit("PHAROS_MANIFEST_PATHS must appear exactly once")

temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text("".join(updated), encoding="utf-8")
temporary.replace(path)
PY

jq --arg host "$host" 'del(.hosts[$host])' "$preferences_file" >"$work_dir/preferences.json"
jq -S . "$work_dir/preferences.json" >"$preferences_file"

successor_json=null
if [[ -n "$successor" ]]; then
  successor_json=$(jq -Rn --arg successor "$successor" '$successor')
fi
jq \
  --arg host "$host" \
  --arg disposition "$disposition" \
  --argjson successor "$successor_json" \
  '.retirements += [{
    host: $host,
    disposition: $disposition,
    successor: $successor,
    credential_retirement_required: true,
    server_deletion: false
  }] | .retirements |= sort_by(.host)' \
  "$retirements_file" >"$work_dir/retirements.json"
jq -S . "$work_dir/retirements.json" >"$retirements_file"

python3 - "$manifest_file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit("manifest disappeared before removal")
path.unlink()
PY

jq -e --arg host "$host" '.hosts[$host] == null' "$preferences_file" >/dev/null || fail preference_cleanup_failed
jq -e \
  --arg host "$host" \
  --arg disposition "$disposition" \
  --argjson successor "$successor_json" \
  '[.retirements[] | select(
    .host == $host
    and .disposition == $disposition
    and .successor == $successor
    and .credential_retirement_required == true
    and .server_deletion == false
  )] | length == 1' \
  "$retirements_file" >/dev/null || fail retirement_record_failed
[[ ! -e "$manifest_file" ]] || fail manifest_cleanup_failed
if grep -Fq "/manifests/$manifest_name" "$compose_file"; then
  fail compose_manifest_cleanup_failed
fi

if [[ ${PHAROS_REMOVAL_FIXTURE:-0} != 1 ]]; then
  changed_paths=()
  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] && changed_paths+=("$changed_path")
  done < <(
    git -C "$repo_root" status --porcelain=v1 --untracked-files=all |
      sed -E 's/^.. //' |
      LC_ALL=C sort
  )
  allowed_paths=(
    "hosts/csb1/docker/docker-compose.yml"
    "hosts/csb1/docker/janus/pharos-production/retired-hosts.json"
    "hosts/csb1/docker/pharos/manifests/$manifest_name"
    "modules/pharos-host-preferences.json"
  )
  [[ ${#changed_paths[@]} -eq ${#allowed_paths[@]} ]] || fail unexpected_changed_paths
  for index in "${!allowed_paths[@]}"; do
    [[ "${changed_paths[$index]}" == "${allowed_paths[$index]}" ]] || fail unexpected_changed_paths
  done
fi

if [[ -n "$output_file" ]]; then
  {
    printf 'changed=true\n'
    printf 'host=%s\n' "$host"
    printf 'manifest=%s\n' "$manifest_name"
    printf 'credential_retirement=pending_janus_owner\n'
  } >>"$output_file"
fi

printf 'pharos_host_removal=prepared host=%s deployment=not_performed credential_retirement=pending_janus_owner\n' "$host"
