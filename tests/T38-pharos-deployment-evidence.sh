#!/usr/bin/env bash
# NIX-348: active-generation evidence and exact Pharos freshness wiring.
#
# OPS-186 (2026-08-21): the beacon must reach the evidence through the tmpfs
# DIRECTORY /run/pharos-deployment, refreshed by flake.nix's activation script.
# Bind-mounting /etc/pharos-deployment/evidence.json (a symlink into the active
# generation) pinned the inode at container start, so every later switch was
# invisible to Pharos; mounting /etc/pharos-deployment as a directory has the
# same defect one level up. Both shapes are rejected below.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hosts=(csb0 csb1 hsb0 hsb1 hsb8 hsb9)

service_block() {
  awk -v heading="    ${2} = {" '
    $0 == heading { found = 1 }
    found { print }
    found && $0 == "    };" { found = 0 }
  ' "$1"
}

unit_result=$(nix eval --json --file "$repo_root/tests/pharos-deployment-evidence-eval.nix")
jq -e '
  .evidence.schema == "inspr.pharos.nix-deployment-evidence.v1"
  and .evidence.version == 1
  and (.evidence.source_revision | test("^[0-9a-f]{40}$"))
  and (.evidence.flake_lock_sha256 | test("^[0-9a-f]{64}$"))
  and (.evidence.nixpkgs_revision | test("^[0-9a-f]{40,64}$"))
  and (.evidence.nixpkgs_last_modified | type == "number" and . >= 1)
  and (.evidence.nixpkgs_channel | test("^[A-Za-z0-9._-]{1,64}$"))
  and ([.checks[]] | all)
' <<<"$unit_result" >/dev/null

expected_lock_sha256=$(shasum -a 256 "$repo_root/flake.lock" | awk '{ print $1 }')
actual_lock_sha256=$(jq -r '.evidence.flake_lock_sha256' <<<"$unit_result")
if [[ "$actual_lock_sha256" != "$expected_lock_sha256" ]]; then
  printf 'pharos_evidence=failed reason=lock_digest_mismatch\n' >&2
  exit 1
fi
evidence_json=$(jq -c '.evidence' <<<"$unit_result")
jq -e --argjson evidence "$evidence_json" '
  (.nodes[.root].inputs.nixpkgs | if type == "array" then .[0] else . end) as $target
  | .nodes[$target].locked.rev == $evidence.nixpkgs_revision
  and .nodes[$target].locked.lastModified == $evidence.nixpkgs_last_modified
  and .nodes[$target].original.ref == $evidence.nixpkgs_channel
' "$repo_root/flake.lock" >/dev/null

for host in "${hosts[@]}"; do
  compose="$repo_root/hosts/$host/docker/compose-spec.nix"
  beacon=$(service_block "$compose" pharos-beacon)

  for exact in \
    '        "PHAROS_NIX_DEPLOYMENT_EVIDENCE_FILE=/host/pharos-deployment/evidence.json"' \
    '        "PHAROS_NIXCFG_REMOTE_URL=https://github.com/markus-barta/nixcfg.git"' \
    '        "PHAROS_NIXCFG_REMOTE_REF=refs/heads/main"' \
    '        "PHAROS_NIXPKGS_REMOTE_URL=https://github.com/NixOS/nixpkgs.git"' \
    '        "/run/pharos-deployment:/host/pharos-deployment:ro" # OPS-186: directory, not the file — see flake.nix activation script' \
    '        "/home/mba/Code/nixcfg:/nixcfg:ro"'; do
    if [[ "$(grep -Fxc -- "$exact" <<<"$beacon")" != 1 ]]; then
      printf 'pharos_evidence=failed reason=missing_or_duplicate host=%s line=%s\n' \
        "$host" "$exact" >&2
      exit 1
    fi
  done

  if grep -Eq -- ':/host/pharos-deployment/evidence.json:(rw|ro,rw)|:/nixcfg:(rw|ro,rw)' <<<"$beacon"; then
    printf 'pharos_evidence=failed reason=writable_source_mount host=%s\n' "$host" >&2
    exit 1
  fi
  if grep -Eq -- '^[[:space:]]+"/(etc|run|nix/store):' <<<"$beacon"; then
    printf 'pharos_evidence=failed reason=broad_host_mount host=%s\n' "$host" >&2
    exit 1
  fi
  if grep -Fq -- '"/etc/pharos-deployment:/host/pharos-deployment:' <<<"$beacon"; then
    printf 'pharos_evidence=failed reason=symlink_preserving_directory_mount host=%s\n' "$host" >&2
    exit 1
  fi
  # OPS-186: the file mount pins the generation active when the container started.
  if grep -Fq -- 'pharos-deployment/evidence.json:/host/' <<<"$beacon"; then
    printf 'pharos_evidence=failed reason=generation_pinning_file_mount host=%s\n' "$host" >&2
    exit 1
  fi
  if grep -Eq -- 'PHAROS_NIX(CFG|PKGS)_REMOTE_URL=https://[^/]*@' <<<"$beacon"; then
    printf 'pharos_evidence=failed reason=credential_bearing_remote host=%s\n' "$host" >&2
    exit 1
  fi
done

# On a clean checkout, prove the generation facts are exactly the values used by
# nixos-version --configuration-revision and --revision for every server. Local
# uncommitted iteration exercises the pure failure fixtures above; CI/review runs
# this clean-flake branch.
if [[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then
  evidence=$(nix eval --json "$repo_root#nixDeploymentEvidence")
  configuration_revisions=$(
    nix eval --json "$repo_root#nixosConfigurations" \
      --apply 'configs: builtins.mapAttrs (_: system: system.config.system.configurationRevision) configs'
  )
  nixpkgs_revisions=$(
    nix eval --json "$repo_root#nixosConfigurations" \
      --apply 'configs: builtins.mapAttrs (_: system: system.config.system.nixos.revision) configs'
  )
  generation_evidence=$(
    nix eval --json "$repo_root#nixosConfigurations" \
      --apply 'configs: builtins.mapAttrs (_: system: builtins.fromJSON system.config.environment.etc."pharos-deployment/evidence.json".text) configs'
  )

  source_revision=$(jq -r '.source_revision' <<<"$evidence")
  nixpkgs_revision=$(jq -r '.nixpkgs_revision' <<<"$evidence")
  for host in "${hosts[@]}"; do
    jq -e --arg host "$host" --arg revision "$source_revision" \
      '.[$host] == $revision' <<<"$configuration_revisions" >/dev/null
    jq -e --arg host "$host" --arg revision "$nixpkgs_revision" \
      '.[$host] == $revision' <<<"$nixpkgs_revisions" >/dev/null
    jq -e --arg host "$host" --argjson evidence "$evidence" \
      '.[$host] == $evidence' <<<"$generation_evidence" >/dev/null
  done
else
  printf 'pharos_evidence=note clean_generation_eval=skipped reason=dirty_worktree\n'
fi

nix-instantiate --parse "$repo_root/flake.nix" >/dev/null
nix-instantiate --parse "$repo_root/lib/pharos-deployment-evidence.nix" >/dev/null
nix-instantiate --parse "$repo_root/tests/pharos-deployment-evidence-eval.nix" >/dev/null

printf 'pharos_evidence=passed hosts=%s\n' "${#hosts[@]}"
