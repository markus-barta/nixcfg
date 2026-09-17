#!/usr/bin/env bash
# T84 — NIX-506: uzumaki HM must materialize the pinned INSPR kernel into
# Pi's global AGENTS.md without force and without bumping the atelier pin.
# Pure/static only: never evaluates or builds a Home Manager configuration.
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

grep -q 'home.file.".pi/agent/AGENTS.md"' "$module" || fail "module does not declare ~/.pi/agent/AGENTS.md"

grep -q 'inputs.inspr-modules}/docs/AGENTS-KERNEL.md' "$module" || fail "module does not source the pinned inspr-modules kernel"

if grep -Eq 'force[[:space:]]*=' "$module"; then
  fail "module must not set home.file force"
fi

nix-instantiate --parse "$module" >/dev/null || fail "agent-kernel.nix does not parse"

if grep -q 'inspr-modules.url' "$flake"; then
  :
else
  fail "flake.nix lost the inspr-modules pin"
fi

# This ticket must not retarget the atelier pin.
python3 - "$flake" "$repo_root/flake.lock" <<'PY'
import pathlib, re, sys, json
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
