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
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lint="${repo}/doctrine/tests/model-role-doctrine.sh"

if [ ! -f "${lint}" ]; then
  echo "T88: ${lint} missing — init the doctrine submodule (git submodule update --init doctrine)" >&2
  exit 1
fi

bash "${lint}" --self-test
bash "${lint}" --lint "${repo}" modules/uzumaki AGENTS.md AGENTS-NIXCFG.md .claude
echo "T88 ok"
