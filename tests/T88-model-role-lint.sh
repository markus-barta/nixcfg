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
# Surfaces: the lint recurses with `grep -r`, which does NOT descend symlinks.
# `.claude/commands` is a symlink to `+agents/commands`, whose entries are
# themselves symlinks into doctrine/ and doctrine-private/ — so directories
# alone would scan nothing there. Real files: +agents/README.md, +agents/rules/.
# Command files are enumerated one by one (a symlink named on the command line
# IS followed); a dangling one (doctrine-private is not checked out in CI, only
# the public doctrine submodule is) is reported and skipped, never a pass.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lint="${repo}/doctrine/tests/model-role-doctrine.sh"

if [ ! -f "${lint}" ]; then
  echo "T88: ${lint} missing — init the doctrine submodule (git submodule update --init doctrine)" >&2
  exit 1
fi

surfaces=(modules/uzumaki AGENTS.md AGENTS-NIXCFG.md +agents)
covered=0
skipped=0
for entry in "${repo}"/+agents/commands/*; do
  rel="${entry#"${repo}"/}"
  if [ -e "${entry}" ]; then
    surfaces+=("${rel}")
    covered=$((covered + 1))
  else
    echo "T88: ${rel} -> $(readlink "${entry}") not checked out here; skipped" >&2
    skipped=$((skipped + 1))
  fi
done
if [ "${covered}" -eq 0 ]; then
  echo "T88: no command file resolved under +agents/commands — nothing linted there" >&2
  exit 1
fi

bash "${lint}" --self-test
bash "${lint}" --lint "${repo}" "${surfaces[@]}"
echo "T88 ok (${covered} command file(s) linted, ${skipped} not checked out)"
