#!/usr/bin/env bash
set -euo pipefail

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$script_root

usage() {
  printf 'usage: %s [--root PATH] [--allow-exact-rollback TAG] RELEASE_METADATA_JSON\n' \
    "${0##*/}" >&2
  exit 2
}

rollback_tag=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
  --root)
    [[ $# -ge 3 ]] || usage
    repo_root=$(cd "$2" && pwd)
    shift 2
    ;;
  --allow-exact-rollback)
    [[ $# -ge 3 ]] || usage
    rollback_tag=$2
    shift 2
    ;;
  *) usage ;;
  esac
done

[[ $# -eq 1 ]] || usage
candidate=$1
release_file="$repo_root/pharos-release.json"

[[ -f "$release_file" ]] || {
  printf 'pharos_release_update=failed reason=unexpected_repository_layout\n' >&2
  exit 1
}

normalized=$(mktemp "${TMPDIR:-/tmp}/pharos-release-next.XXXXXX")
trap 'rm -f "$normalized"' EXIT
candidate_schema=$(jq -er .schema "$candidate")
if [[ "$candidate_schema" == inspr.pharos.release-set.v1 ]]; then
  [[ -z "$rollback_tag" ]] || usage
  python3 "$script_root/scripts/pharos-release-metadata.py" transition \
    --active "$release_file" \
    --candidate "$candidate" \
    --output "$normalized"
elif [[ "$candidate_schema" == inspr.pharos.fleet-release.v2 ]]; then
  if python3 "$script_root/scripts/pharos-release-metadata.py" matches \
    --active "$release_file" \
    --candidate "$candidate" >/dev/null 2>&1; then
    cp "$candidate" "$normalized"
  elif [[ -n "$rollback_tag" ]]; then
    python3 "$script_root/scripts/pharos-release-metadata.py" rollback \
      --active "$release_file" \
      --tag "$rollback_tag" \
      --output "$normalized"
    python3 "$script_root/scripts/pharos-release-metadata.py" matches \
      --active "$normalized" \
      --candidate "$candidate"
  else
    printf 'pharos_release_update=failed reason=local_target_requires_exact_rollback\n' >&2
    exit 1
  fi
else
  printf 'pharos_release_update=failed reason=unsupported_metadata_schema\n' >&2
  exit 1
fi

current_reference=$(jq -er .reference "$release_file")
current_version=$(jq -er .version "$release_file")
reference=$(jq -er .reference "$normalized")
version=$(jq -er .version "$normalized")
digest=$(jq -er .digest "$normalized")

python3 - \
  "$repo_root" \
  "$current_reference" \
  "$current_version" \
  "$reference" \
  "$version" \
  "$normalized" \
  "$release_file" <<'PY'
import os
import re
import sys
import tempfile

root, current_reference, current_version, replacement, version, normalized, release_file = sys.argv[1:]
# OPS-127: the compose specs are the source of truth (the ymls are retired);
# service blocks are nix attrsets closing at indent-4 "};", image lines are
#   image = "ghcr.io/inspr-at/pharos/pharosd:VERSION@sha256:...";
targets = (
    ("hosts/csb0/docker/compose-spec.nix", ("pharos-beacon",)),
    ("hosts/csb1/docker/compose-spec.nix", ("pharosd", "pharos-beacon")),
    ("hosts/hsb0/docker/compose-spec.nix", ("pharos-beacon",)),
    ("hosts/hsb1/docker/compose-spec.nix", ("pharos-beacon",)),
    ("hosts/hsb8/docker/compose-spec.nix", ("pharos-beacon",)),
    ("hosts/hsb9/docker/compose-spec.nix", ("pharos-beacon",)),
)
pending = []

for relative, services in targets:
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        raise SystemExit(f"pharos_release_update=failed reason=compose_missing path={relative}")
    with open(path, encoding="utf-8") as handle:
        lines = handle.readlines()
    for service in services:
        heading = f"    {service} = {{"
        starts = [i for i, line in enumerate(lines) if line.rstrip("\n") == heading]
        if len(starts) != 1:
            raise SystemExit(
                f"pharos_release_update=failed reason=unexpected_service_count path={relative} service={service}"
            )
        start = starts[0]
        end = next(
            (i for i in range(start + 1, len(lines)) if lines[i].rstrip("\n") == "    };"),
            len(lines),
        )
        image_lines = [
            i
            for i in range(start + 1, end)
            if re.match(r"^      image = \"ghcr\.io/inspr-at/pharos/pharosd:", lines[i])
        ]
        if len(image_lines) != 1:
            raise SystemExit(
                f"pharos_release_update=failed reason=unexpected_image_count path={relative} service={service}"
            )
        index = image_lines[0]
        old = lines[index].split("=", 1)[1].strip().strip(';').strip('"')
        if old != current_reference:
            raise SystemExit(
                f"pharos_release_update=failed reason=existing_pin_manifest_mismatch path={relative} service={service}"
            )
        lines[index] = f'      image = "{replacement}";\n'
    pending.append((path, lines))

readiness_relative = "hosts/csb1/docker/janus/managed-service-production/readiness.sh"
readiness_path = os.path.join(root, readiness_relative)
if not os.path.isfile(readiness_path):
    raise SystemExit(
        f"pharos_release_update=failed reason=readiness_missing path={readiness_relative}"
    )
with open(readiness_path, encoding="utf-8") as handle:
    readiness = handle.read()
escaped_current_version = re.escape(current_version)
readiness_pattern = re.compile(
    re.escape(
        rf"^ghcr\.io/inspr-at/pharos/pharosd:{escaped_current_version}"
        r"@sha256:[0-9a-f]{64}$"
    )
)
escaped_version = re.escape(version)
expected_readiness = (
    rf"^ghcr\.io/inspr-at/pharos/pharosd:{escaped_version}"
    r"@sha256:[0-9a-f]{64}$"
)
readiness, count = readiness_pattern.subn(lambda _: expected_readiness, readiness)
if count != 1:
    raise SystemExit(
        f"pharos_release_update=failed reason=unexpected_readiness_pin_count path={readiness_relative}"
    )
pending.append((readiness_path, readiness.splitlines(keepends=True)))

with open(normalized, encoding="utf-8") as handle:
    pending.append((release_file, handle.readlines()))

for path, lines in pending:
    mode = os.stat(path).st_mode
    fd, temporary = tempfile.mkstemp(prefix=".pharos-release-", dir=os.path.dirname(path), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.writelines(lines)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
PY

printf 'pharos_release_update=passed version=%s digest=%s\n' "$version" "$digest"
