#!/usr/bin/env bash
# OPS-106: a dirty-tree build must never ship silently.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common="${repo}/modules/common.nix"

# The revision is what the fleet uses to tell what a host is running; without it
# /etc/pharos/deployed-revision reads "unavailable" and drift is unmeasurable.
grep -Fq 'system.configurationRevision = inputs.self.rev or null;' "${common}"
grep -Fq 'environment.etc."pharos/deployed-revision"' "${common}"

# A dirty build must WARN. Deliberately a warning and not an assertion: building
# from a dirty tree is legitimate while iterating, it just must not be silent.
grep -Fq 'warnings = lib.optional (config.system.configurationRevision == null)' "${common}"
if grep -Eq 'assertions.*configurationRevision == null' "${common}"; then
  printf 'dirty-tree builds must warn, not fail — iterating locally has to stay possible\n' >&2
  exit 1
fi

# `just switch` must state the revision (or DIRTY) it is about to deploy.
grep -Fq 'deploying a DIRTY tree' "${repo}/justfile"
grep -Fq 'git rev-parse --short HEAD' "${repo}/justfile"

nix-instantiate --parse "${common}" >/dev/null

printf 'OPS-106 revision-traceability contract: OK\n'
