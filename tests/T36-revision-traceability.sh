#!/usr/bin/env bash
# OPS-106: a dirty-tree build must never ship silently.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common="${repo}/modules/common.nix"
flake="${repo}/flake.nix"

# The revision is what the fleet uses to tell what a host is running; without it
# both the legacy revision file and the NIX-348 evidence would be untrustworthy.
grep -Fq 'system.configurationRevision = nixDeploymentEvidence.source_revision;' "${flake}"
grep -Fq 'environment.etc."pharos/deployed-revision"' "${common}"

# NIX-348 supersedes the warning-only OPS-106 boundary for NixOS generations:
# revisionless production evaluation must now fail before it can emit evidence.
grep -Fq 'source_revision = requireGitRevision "self.rev" (self.rev or null);' \
  "${repo}/lib/pharos-deployment-evidence.nix"
if grep -Fq 'configurationRevision == null' "${common}"; then
  printf 'revisionless NixOS generations must fail closed, not emit unavailable\n' >&2
  exit 1
fi

# `just switch` must state the revision (or DIRTY) it is about to deploy.
grep -Fq 'deploying a DIRTY tree' "${repo}/justfile"
grep -Fq 'git rev-parse --short HEAD' "${repo}/justfile"

nix-instantiate --parse "${common}" >/dev/null
nix-instantiate --parse "${flake}" >/dev/null

printf 'OPS-106/NIX-348 revision-traceability contract: OK\n'
