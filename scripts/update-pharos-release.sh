#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
  printf 'usage: %s [--root PATH] VERSION SHA256_DIGEST\n' "${0##*/}" >&2
  exit 2
}

if [[ "${1:-}" == "--root" ]]; then
  [[ $# -ge 4 ]] || usage
  repo_root=$(cd "$2" && pwd)
  shift 2
fi

[[ $# -eq 2 ]] || usage
version=$1
digest=$2

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'pharos_release_update=failed reason=invalid_version\n' >&2
  exit 1
}
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  printf 'pharos_release_update=failed reason=invalid_digest\n' >&2
  exit 1
}

image=ghcr.io/inspr-at/pharos/pharosd
reference="${image}:${version}@${digest}"
release_file="$repo_root/pharos-release.json"

[[ -f "$release_file" ]] || {
  printf 'pharos_release_update=failed reason=unexpected_repository_layout\n' >&2
  exit 1
}

python3 - "$repo_root" "$reference" <<'PY'
import os
import re
import sys
import tempfile

root, replacement = sys.argv[1:]
targets = (
    ("hosts/csb0/docker/docker-compose.yml", ("pharos-beacon",)),
    ("hosts/csb1/docker/docker-compose.yml", ("pharosd", "pharos-beacon")),
    ("hosts/gpc0/docker/docker-compose.yml", ("pharos-beacon",)),
    ("hosts/hsb0/docker/docker-compose.yml", ("pharos-beacon",)),
    ("hosts/hsb1/docker/docker-compose.yml", ("pharos-beacon",)),
    ("hosts/hsb8/docker/docker-compose.yml", ("pharos-beacon",)),
    ("hosts/hsb9/docker/docker-compose.yml", ("pharos-beacon",)),
)
immutable = re.compile(
    r"ghcr\.io/inspr-at/pharos/pharosd:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}"
)
pending = []

for relative, services in targets:
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        raise SystemExit(f"pharos_release_update=failed reason=compose_missing path={relative}")
    with open(path, encoding="utf-8") as handle:
        lines = handle.readlines()
    for service in services:
        heading = f"  {service}:"
        starts = [i for i, line in enumerate(lines) if line.rstrip("\n") == heading]
        if len(starts) != 1:
            raise SystemExit(
                f"pharos_release_update=failed reason=unexpected_service_count path={relative} service={service}"
            )
        start = starts[0]
        end = next(
            (i for i in range(start + 1, len(lines)) if re.match(r"^  [^ ]", lines[i])),
            len(lines),
        )
        image_lines = [
            i
            for i in range(start + 1, end)
            if re.match(r"^    image: ghcr\.io/inspr-at/pharos/pharosd:", lines[i])
        ]
        if len(image_lines) != 1:
            raise SystemExit(
                f"pharos_release_update=failed reason=unexpected_image_count path={relative} service={service}"
            )
        index = image_lines[0]
        old = lines[index].split("image:", 1)[1].strip()
        if not immutable.fullmatch(old):
            raise SystemExit(
                f"pharos_release_update=failed reason=existing_pin_not_immutable path={relative} service={service}"
            )
        lines[index] = f"    image: {replacement}\n"
    pending.append((path, lines))

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

python3 - "$release_file" "$version" "$digest" "$image" "$reference" <<'PY'
import json
import os
import sys
import tempfile

path, version, digest, image, reference = sys.argv[1:]
document = {
    "schema": "inspr.pharos.fleet-release.v1",
    "version": version,
    "tag": f"v{version}",
    "image": image,
    "digest": digest,
    "reference": reference,
}
mode = os.stat(path).st_mode
fd, temporary = tempfile.mkstemp(prefix=".pharos-release-", dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
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
