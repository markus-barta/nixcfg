#!/usr/bin/env bash
# NIX-568 — nixcfg's agent-instruction surfaces name roles, never models.
#
# INSPR-463 made model choice role-based: doctrine, skills and prompts name a
# role and resolve it with `paimos model resolve`; concrete model ids live only
# in the Paimos registry (PAI-1048). inspr-modules ships the lint; this runs it
# over the surfaces nixcfg carries itself. Runtime configuration (pi-local.nix,
# codex-doctor.sh, openclaw.json, the justfile) is deliberately NOT linted: a
# tool default is not a routing decision. A hit is fixed by rewriting to a role
# (AGENTS-DOMAIN-DEV.md § model choice by role), never by an exemption.
#
# Surfaces: the lint recurses with `grep -r`, which does NOT descend symlinks —
# and BSD grep (macOS) skips even a symlink named on the command line, GNU grep
# follows it. `.claude/commands` is a symlink to `+agents/commands`, whose
# entries are themselves symlinks into doctrine/ and doctrine-private/, so
# directories or symlink names alone would scan nothing there on a Mac while
# passing on Linux. Real files: +agents/README.md, +agents/rules/. Command files
# are resolved to their root-relative REGULAR-file targets. A target under
# doctrine-private/ may be absent (CI checks out only the public doctrine
# submodule) and is reported and skipped; any other dangling link fails.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lint="${repo}/doctrine/tests/model-role-doctrine.sh"

if [ ! -f "${lint}" ]; then
  echo "T88: ${lint} missing — init the doctrine submodule (git submodule update --init doctrine)" >&2
  exit 1
fi

# Root-relative path of a symlink's target, resolved lexically (no realpath /
# GNU coreutils dependency; bash 3.2 + python3 are what CI and macOS have).
resolve_target() {
  python3 - "$1" <<'PY'
import os
import sys

link = sys.argv[1]
target = os.readlink(link)
print(os.path.normpath(os.path.join(os.path.dirname(link), target)))
PY
}

surfaces=(modules/uzumaki AGENTS.md AGENTS-NIXCFG.md +agents)
covered=0
skipped=0
cd "${repo}"
for entry in +agents/commands/*; do
  if [ ! -L "${entry}" ]; then
    echo "T88: ${entry} is not a symlink into doctrine; lint it via +agents" >&2
    continue
  fi
  target="$(resolve_target "${entry}")"
  if [ -f "${target}" ]; then
    surfaces+=("${target}")
    covered=$((covered + 1))
  elif [ "${target#doctrine-private/}" != "${target}" ] && [ ! -f doctrine-private/README.md ]; then
    echo "T88: ${entry} -> ${target}: private doctrine not checked out here; skipped" >&2
    skipped=$((skipped + 1))
  else
    echo "T88: ${entry} -> ${target} is dangling" >&2
    exit 1
  fi
done
if [ "${covered}" -eq 0 ]; then
  echo "T88: no command file resolved under +agents/commands — nothing linted there" >&2
  exit 1
fi

bash "${lint}" --self-test
bash "${lint}" --lint "${repo}" "${surfaces[@]}"
echo "T88 ok (${covered} command file(s) linted as regular files, ${skipped} private not checked out)"
