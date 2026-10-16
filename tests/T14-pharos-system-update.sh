#!/usr/bin/env bash
set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/pharos-system-update.yml"
prepare="$repo_root/scripts/prepare-pharos-system-update.sh"

bash -n "$prepare"
bash -n "$repo_root/modules/pharos-guarded-deploy/system-update.sh"
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
# Only remove the temporary fixture this test created, as in the Python cases below.
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$fixture_root"' EXIT
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
    "root": { "inputs": { "nixpkgs": "nixpkgs", "hausnetz": "hausnetz", "alias": ["nixpkgs"] } },
    "hausnetz": {
      "locked": { "type": "git", "rev": "reviewed-pinned-revision" },
      "original": { "type": "git", "rev": "reviewed-pinned-revision" }
    },
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
    "root": { "inputs": { "nixpkgs": "nixpkgs", "hausnetz": "hausnetz", "alias": ["nixpkgs"] } },
    "hausnetz": {
      "locked": { "type": "git", "rev": "reviewed-pinned-revision" },
      "original": { "type": "git", "rev": "reviewed-pinned-revision" }
    },
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
  # OPS-207: update real selected inputs; never all inputs or the pinned app.
  [[ "$#" == 3 && "$3" == nixpkgs ]] || exit 1
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

# Exercise the actual on-host all-host evaluation block without running its
# preflight, build, activation or reboot paths. CI's proposal still evaluates
# every host with its own read-only private-input key.
python3 - "$repo_root" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
module = (repo / 'modules/pharos-guarded-deploy/default.nix').read_text()
source = (repo / 'modules/pharos-guarded-deploy/system-update.sh').read_text()
assert '(lib.escapeShellArgs cfg.privateInputHosts)' in module
assert '(lib.boolToString cfg.canEvaluatePrivateInputs)' in module
assert 'readonly PRIVATE_INPUT_HOSTS=(@PRIVATE_INPUT_HOSTS@)' in source
assert "readonly CAN_EVALUATE_PRIVATE_INPUTS='@CAN_EVALUATE_PRIVATE_INPUTS@'" in source
declared = re.search(r'privateInputHosts = lib.mkOption \{.*?default = \[([^]]*)\];', module, re.S)[1]
private_hosts = re.findall(r'"([a-z0-9-]+)"', declared)
assert private_hosts == ['hsb0'], private_hosts
assert re.search(r'canEvaluatePrivateInputs = lib.mkOption \{.*?default = host == "hsb0";', module, re.S)
block = "  stage='all_host_evaluation'" + source.split("  stage='all_host_evaluation'", 1)[1].split("  stage='target_build'", 1)[0]
# Exercise the real plan writer too: skipped hosts must survive into the public
# review plan, while evaluation failure must stop before a success plan exists.
plan_block = "  jq -Rsc " + source.split("  jq -Rsc ", 1)[1].split("  printf 'null", 1)[0]
hosts = ['csb0', 'csb1', 'hsb0', 'hsb1', 'hsb8', 'hsb9']

with tempfile.TemporaryDirectory(prefix='ops207-guard-') as tmp:
    root = Path(tmp)
    nix = root / 'nix'
    nix.write_text('''#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' --json '* ]]; then
  printf '%s\\n' '["hsb9","hsb8","hsb1","hsb0","csb1","csb0"]'
else
  ref="${*: -1}"
  host="${ref#*#nixosConfigurations.}"
  host="${host%%.*}"
  printf '%s\\n' "$host" >> "$EVAL_CALLS"
  [[ "$host" != "$FAIL_HOST" ]]
fi
''')
    nix.chmod(0o700)
    calls = root / 'calls'
    child_env = dict(os.environ, PATH=f'{root}:' + os.environ['PATH'], EVAL_CALLS=str(calls))
    for case, (evaluator, access, fail_host) in enumerate([('hsb8', 'false', ''), ('hsb8', 'true', ''), ('hsb0', 'false', ''), ('hsb8', 'false', 'csb1'), ('hsb8', 'false', 'hsb9'), ('hsb0', 'false', 'hsb0')]):
        calls.write_text('')
        action = root / f'case-{case}'
        action.mkdir()
        (action / 'changed-areas').write_text('host-config\n')
        detail = root / 'detail.log'
        detail.write_text('')
        child_env.update(HOST=evaluator, CAN_EVALUATE_PRIVATE_INPUTS=access, FAIL_HOST=fail_host, action_dir=str(action), repo_dir=tmp, detail_log=str(detail), changed_areas=str(action / 'changed-areas'), changed_file_count='1', running_kernel='fixture-kernel', expected_kernel='fixture-kernel')
        script = 'set -Eeuo pipefail\nPRIVATE_INPUT_HOSTS=(' + ' '.join(private_hosts) + ')\n' + block + plan_block
        result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
        actual = calls.read_text().splitlines()
        if fail_host:
            assert result.returncode != 0, 'any evaluated host failure must close the gate'
            assert not (action / 'plan.json').exists()
        else:
            assert result.returncode == 0, result.stderr
            expected = [h for h in hosts if not (h == 'hsb0' and access == 'false' and evaluator != 'hsb0')]
            assert actual == expected, (evaluator, access, actual)
            plan = json.loads((action / 'plan.json').read_text())
            assert plan['skippedHosts'] == [h for h in hosts if h not in expected]
            assert plan['all_host_eval_passed'] is True
            assert plan['target_build_passed'] is True
            message = 'hsb0 skipped: private input, covered by CI'
            if expected != hosts:
                assert message in result.stdout and message in detail.read_text()
            else:
                assert 'skipped:' not in result.stdout + detail.read_text()
print('OPS-207 guarded private-input evaluation: OK')
PY

echo 'pharos_system_update=passed'
