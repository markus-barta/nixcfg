#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/pharos-system-update.yml"
prepare="$repo_root/scripts/prepare-pharos-system-update.sh"

bash -n "$prepare"
grep -Fq 'workflow_dispatch:' "$workflow"
grep -Fq 'source_host:' "$workflow"
grep -Fq 'request_id:' "$workflow"
grep -Fq 'add-paths: flake.lock' "$workflow"
grep -Fq 'branch: automation/pharos-system-update' "$workflow"
grep -Fq 'deployment=not_performed' "$workflow"
grep -Fq 'scripts/prepare-pharos-system-update.sh' "$workflow"

if grep -Eq 'gh pr merge|nixos-rebuild|switch-to-configuration|--force|auto-merge' "$workflow"; then
  echo 'unsafe merge or deployment authority found in update proposal workflow' >&2
  exit 1
fi

fixture_root=$(mktemp -d)
trap 'rm -r "$fixture_root"' EXIT
fixture="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$fixture" "$fake_bin"

cp "$prepare" "$fixture/prepare.sh"
chmod +x "$fixture/prepare.sh"

cat >"$fixture/flake.nix" <<'EOF'
{
  outputs = _: { };
}
EOF

cat >"$fixture/flake.lock" <<'EOF'
{
  "nodes": {
    "root": { "inputs": { "nixpkgs": "nixpkgs" } },
    "nixpkgs": {
      "locked": { "type": "github", "rev": "old-revision" },
      "original": { "type": "github", "owner": "NixOS", "repo": "nixpkgs" }
    }
  },
  "root": "root",
  "version": 7
}
EOF

cat >"$fixture_root/updated.lock" <<'EOF'
{
  "nodes": {
    "root": { "inputs": { "nixpkgs": "nixpkgs" } },
    "nixpkgs": {
      "locked": {
        "type": "github",
        "rev": "new-revision",
        "narHash": "private-digest"
      },
      "original": { "type": "github", "owner": "NixOS", "repo": "nixpkgs" }
    }
  },
  "root": "root",
  "version": 7
}
EOF

cat >"$fake_bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1-}" == flake && "${2-}" == update ]]; then
  cp "$FAKE_UPDATED_LOCK" flake.lock
  echo 'update diagnostic private-digest' >&2
  exit 0
fi

if [[ "${1-}" == eval && " $* " == *' --json '* && " $* " == *' --apply '* ]]; then
  printf '["hsb8","csb1"]\n'
  exit 0
fi

if [[ "${1-}" == eval ]]; then
  printf '%s\n' "$*" >>"$FAKE_EVAL_LOG"
  echo '/nix/store/private-build-result'
  echo 'evaluation diagnostic private-digest' >&2
  exit 0
fi

exit 1
EOF
chmod +x "$fake_bin/nix"

(
  cd "$fixture"
  git init -q
  git config user.name 'Pharos test'
  git config user.email 'pharos-test@example.invalid'
  git add flake.nix flake.lock prepare.sh
  git commit -qm 'fixture'
)

output_file="$fixture_root/github-output"
eval_log="$fixture_root/eval-log"
captured=$(
  cd "$fixture"
  PATH="$fake_bin:$PATH" \
    FAKE_UPDATED_LOCK="$fixture_root/updated.lock" \
    FAKE_EVAL_LOG="$eval_log" \
    GITHUB_OUTPUT="$output_file" \
    ./prepare.sh hsb8 request-test-1 2>&1
)

grep -Fxq 'changed=true' "$output_file"
grep -Fxq 'changed_inputs=nixpkgs' "$output_file"
grep -Fxq 'validated_hosts=csb1, hsb8' "$output_file"
grep -Fxq 'validated_host_count=2' "$output_file"
grep -Fq '#nixosConfigurations.csb1.config.system.build.toplevel.drvPath' "$eval_log"
grep -Fq '#nixosConfigurations.hsb8.config.system.build.toplevel.drvPath' "$eval_log"

if grep -Eq 'old-revision|new-revision|private-digest|/nix/store/' <<<"$captured"; then
  echo 'raw update or evaluation details escaped output suppression' >&2
  exit 1
fi

[[ "$(cd "$fixture" && git diff --name-only)" == 'flake.lock' ]]

if (
  cd "$fixture"
  PATH="$fake_bin:$PATH" \
    FAKE_UPDATED_LOCK="$fixture_root/updated.lock" \
    FAKE_EVAL_LOG="$eval_log" \
    ./prepare.sh '../invalid' request-test-2 >/dev/null 2>&1
); then
  echo 'invalid source host was accepted' >&2
  exit 1
fi

echo 'pharos_system_update=passed'
