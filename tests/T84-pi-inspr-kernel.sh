#!/usr/bin/env bash
# T84 — NIX-511: uzumaki HM loads public+private kernel on four CLIs.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/modules/uzumaki/agent-kernel.nix"
entry="$repo_root/modules/uzumaki/home-manager.nix"
flake="$repo_root/flake.nix"

fail() {
  printf 'T84 failed: %s\n' "$*" >&2
  exit 1
}

[[ -f $module ]] || fail "missing $module"
[[ -f $entry ]] || fail "missing $entry"

grep -q './agent-kernel.nix' "$entry" || fail "home-manager.nix does not import agent-kernel.nix"

grep -q 'homeManagerModules.agent-kernel' "$module" || fail "module does not import the atelier agent-kernel"

grep -q 'inspr.agent-kernel' "$module" || fail "module does not configure inspr.agent-kernel"
grep -q 'enable = true' "$module" || fail "module does not enable inspr.agent-kernel"

grep -q 'extraSources' "$module" || fail "module does not attach extraSources"

grep -q 'markerHarnesses' "$module" || fail "module does not declare marker harnesses"

if grep -Eq 'force[[:space:]]*=' "$module"; then
  fail "module must not set home.file force"
fi

nix-instantiate --parse "$module" >/dev/null || fail "agent-kernel.nix does not parse"

python3 - "$flake" "$repo_root/flake.lock" <<'PY'
import json, pathlib, re, sys

flake = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
lock = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
urls = re.findall(r'inspr-modules\.url\s*=\s*"([^"]+)"', flake)
if len(urls) != 1:
    raise SystemExit(f"expected one inspr-modules.url, got {urls!r}")
rev = urls[0].rsplit("/", 1)[-1]
locked = lock["nodes"]["inspr-modules"]["locked"]["rev"]
if rev != locked:
    raise SystemExit(f"flake.nix pin {rev} != lock {locked}")
PY
