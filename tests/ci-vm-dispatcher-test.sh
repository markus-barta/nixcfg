#!/usr/bin/env bash
# OPS-669: actual module evaluation and dispatcher against offline curl/colima.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old; run with bash 5 to avoid false passes under set -e\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
dispatcher="$root/hosts/mbp2607/files/ci-vm/dispatcher.sh"
mkdir -p "$root/tests/.tmp"
work=$(mktemp -d "$root/tests/.tmp/ci-vm-dispatcher.XXXXXXXX")
# CI runners without trash are disposable. Never rm -rf.
trap 'trash "$work" >/dev/null 2>&1 || true' EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

nix-instantiate --eval --strict --json --arg root "$root" "$root/tests/mbp2607-ci-vm-eval.nix" >"$work/module.json"
jq -e '.checks | all' "$work/module.json" >/dev/null || fail 'module evaluation'
jq .colima "$work/module.json" >"$work/declared.yaml"
jq .repos "$work/module.json" >"$work/repos.json"
echo "ok module: $(jq '.checks | length' "$work/module.json") evaluated contracts"
# Mutate only disposable copies: the eval contracts must reject each regression.
mutant_root="$work/eval-mutant"
mkdir -p "$mutant_root/hosts/mbp2607/files"
cp -R "$root/hosts/mbp2607/files/ci-vm" "$mutant_root/hosts/mbp2607/files/"
cp "$root/hosts/mbp2607/README.md" "$mutant_root/hosts/mbp2607/README.md"
for mutation in cpu background low-io low-background-io starter; do
  python3 - "$root/hosts/mbp2607/ci-vm.nix" "$mutant_root/hosts/mbp2607/ci-vm.nix" "$mutation" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old, new = {
    'cpu': ('cpu = 4;', 'cpu = 6;'),
    'background': ('ProcessType = "Standard";', 'ProcessType = "Background";'),
    'low-io': ('ProcessType = "Standard";', 'ProcessType = "Standard"; LowPriorityIO = true;'),
    'low-background-io': ('ProcessType = "Standard";', 'ProcessType = "Standard"; LowPriorityBackgroundIO = true;'),
    'starter': ('exec /bin/bash', 'exec /usr/sbin/taskpolicy -b -c background /bin/bash'),
}[sys.argv[3]]
assert source.count(old) == 1
Path(sys.argv[2]).write_text(source.replace(old, new))
PY
  if nix-instantiate --eval --strict --json --arg root "$mutant_root" "$root/tests/mbp2607-ci-vm-eval.nix" >"$work/$mutation.json" 2>"$work/$mutation.err"; then
    fail "$mutation eval mutant survived"
  fi
  case "$mutation" in
  cpu) contract=hardCaps ;;
  starter) contract=noBackgroundStarter ;;
  *) contract=standardPolicy ;;
  esac
  grep -q "OPS-669 eval failed: $contract" "$work/$mutation.err" || fail "$mutation eval failed for the wrong reason"
done
echo 'ok eval must-fail: cpu=6, ProcessType=Background, LowPriorityIO, LowPriorityBackgroundIO and taskpolicy starter wrapper are rejected by their contracts'
cp "$root/hosts/mbp2607/ci-vm.nix" "$mutant_root/hosts/mbp2607/ci-vm.nix"
for mutation in wrong-heavy-path heavy-cli-env; do
  python3 - "$root/hosts/mbp2607/files/ci-vm/heavy-lock.py" "$mutant_root/hosts/mbp2607/files/ci-vm/heavy-lock.py" "$mutation" <<'PY_HEAVY_EVAL'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old, new = {
    "wrong-heavy-path": ('LOCK_PATH = "/Users/Shared/ci-locks/mbp2607-heavy.lock.d"', 'LOCK_PATH = "/fixture/wrong-heavy.lock.d"'),
    "heavy-cli-env": ('        action, pid, now, *extra = sys.argv[1:]', '        os.environ.get("CI_VM_HEAVY_LOCK")\n        action, pid, now, *extra = sys.argv[1:]'),
}[sys.argv[3]]
assert source.count(old) == 1
Path(sys.argv[2]).write_text(source.replace(old, new))
PY_HEAVY_EVAL
  if nix-instantiate --eval --strict --json --arg root "$mutant_root" "$root/tests/mbp2607-ci-vm-eval.nix" >"$work/$mutation.json" 2>"$work/$mutation.err"; then
    fail "$mutation eval mutant survived"
  fi
  grep -q 'Heavy helper must bake a constant absolute path and reject CLI path overrides' "$work/$mutation.err" || fail "$mutation eval failed for the wrong reason"
done
echo 'ok eval heavy must-fail: wrong baked path and production CLI environment access rejected'
python3 "$root/tests/ci-vm-host-test.py"
python3 "$root/tests/ci-vm-guest-test.py" "$root" "$work" "$work/module.json"
mkdir -p "$work/bin"
export CI_TEST_REAL_JQ
CI_TEST_REAL_JQ=$(command -v jq)

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
from urllib.parse import parse_qs, urlparse
args = sys.argv[1:]
assert args[0] == "-q", "curl must ignore implicit user config"
assert "--config" in args and args[args.index("--config") + 1] == "-"
assert not any("fixture-agent-value" in a for a in args), "token in argv"
assert "GH_TOKEN" not in os.environ, "token in curl environment"
assert sys.stdin.read() == 'header = "Authorization: Bearer fixture-agent-value"\n', "token not transported on stdin"
url = args[-1]
with open(os.environ["CI_TEST_CALLS"], "a") as f:
    f.write(("POST " if "--request" in args else "GET ") + url + "\n")
assert url.startswith("https://api.github.com/repos/inspr-at/"), url
assert "registration-token" not in url
scenario = os.environ["CI_TEST_SCENARIO"]
if scenario == "failure": sys.exit(22)
if scenario == "mixed" and "/hausnetz/" in url: sys.exit(22)
parsed = urlparse(url)
if "--request" in args:
    assert "--data-raw" in args, "POST body must not be interpreted as a filename"
    payload = json.loads(args[args.index("--data-raw") + 1])
    code = 202 if parsed.path.endswith("/cancel") else 201
    outcome = os.environ.get("CI_TEST_CANCEL", "ok") if code == 202 else os.environ.get("CI_TEST_COMMENT", "ok") if parsed.path.endswith("/comments") else os.environ.get("CI_TEST_ISSUE", "ok")
    if outcome == "timeout":
        print("\n000")
        sys.exit(28)
    if outcome == "403":
        print("\n403")
        sys.exit(22)
    if parsed.path.endswith("/cancel"):
        assert payload == {}
        print('{}')
    elif parsed.path.endswith("/comments"):
        assert "host busy: mbp2607 heavy-CI lock held by " in payload["body"]
        assert "https://github.com/inspr-at/hausnetz/actions/runs/" in payload["body"]
        with open(os.environ["CI_TEST_CALLS"], "a") as f: f.write("COMMENT " + payload["body"] + "\n")
        print('{}')
    elif parsed.path.endswith("/issues"):
        assert payload["title"] == "CI nightly: host busy / cancellations"
        with open(os.environ["CI_VM_STATE_DIR"] + "/nightly-issue", "w") as f: f.write("429")
        print('{"number":429}')
    else: raise AssertionError(url)
    if "--write-out" in args: print("\n" + str(code))
    sys.exit()
if parsed.path.endswith("/issues/429"):
    state = os.environ.get("CI_TEST_ISSUE_STATE", "open")
    if state == "deleted": sys.exit(22)
    print(json.dumps({"number":429,"title":"CI nightly: host busy / cancellations", "state":state, "locked":state == "locked"}))
    sys.exit()
if parsed.path.endswith("/issues"):
    issues = [{"number":429,"title":"CI nightly: host busy / cancellations"}] if os.path.exists(os.environ["CI_VM_STATE_DIR"] + "/nightly-issue") else []
    if os.environ.get("CI_TEST_ISSUE_STATE", "open") != "open": issues = []
    print(json.dumps(issues))
    sys.exit()
query = parse_qs(parsed.query)
page = int(query["page"][0])
is_jobs = parsed.path.endswith("/jobs")
repo = "extra" if "/extra/" in url else "hausnetz"
if parsed.path.endswith("/runners"):
    runners = [] if scenario == "stale-runner" else [{"name": "mbp2607-" + repo}]
    print(json.dumps({"runners": runners, "total_count": len(runners)}))
    sys.exit()
labels = ["self-hosted", "Linux", "ARM64", "mbp2607", repo, "kvm"]
if not is_jobs:
    if scenario == "malformed": print('{}'); sys.exit()
    if scenario == "truncated": print('{"workflow_runs": [], "total_count": 101}'); sys.exit()
    if scenario == "short-runs": print('{"workflow_runs": [], "total_count": 1}'); sys.exit()
    if scenario == "negative-count": print('{"workflow_runs": [], "total_count": -1}'); sys.exit()
    if scenario == "huge-count": print('{"workflow_runs": [], "total_count": 1e100}'); sys.exit()
    status = query["status"][0]
    active = status == ("in_progress" if scenario in {"progress", "foreign-progress"} else "queued")
    active = active and scenario != "empty"
    if scenario == "multiple" and repo == "hausnetz": active = False
    if active and scenario == "run-pages":
        runs = [{"id": i} for i in range(1, 101)] if page == 1 else [{"id": 101}]
        total = 101
    else:
        runs = [{"id": int(os.environ.get("CI_TEST_RUN_ID", "11")),
                 "html_url": "https://github.com/inspr-at/hausnetz/actions/runs/" + os.environ.get("CI_TEST_RUN_ID", "11"),
                 "run_attempt": int(os.environ.get("CI_TEST_RUN_ATTEMPT", "1")),
                 "path": os.environ.get("CI_TEST_WORKFLOW", ".github/workflows/nix.yml"),
                 "pull_requests": [] if os.environ.get("CI_TEST_NIGHTLY") == "1" else [{"number": 42}]}] if active else []
        total = len(runs)
    print(json.dumps({"workflow_runs": runs, "total_count": total}))
else:
    if scenario == "malformed-jobs": print('{"jobs": [{"status":"queued", "labels":null}], "total_count":1}'); sys.exit()
    if scenario == "short-jobs": print('{"jobs": [], "total_count": 1}'); sys.exit()
    if scenario == "wrong-arch": labels[2] = "X64"
    if scenario == "wrong-host": labels[3] = "agm2"
    if scenario == "no-labels": labels = []
    status = "in_progress" if scenario in {"progress", "foreign-progress"} else "completed" if scenario == "completed" else "queued"
    jobs = [{"status": status, "labels": labels, "runner_name": "another-runner" if scenario == "foreign-progress" else "mbp2607-" + repo}]
    total = 1
    if scenario == "run-pages" and not parsed.path.endswith("/101/jobs"): jobs, total = [], 0
    if scenario == "job-pages":
        jobs = [{"status": "completed", "labels": labels}] * 100 if page == 1 else jobs
        total = 101
    print(json.dumps({"jobs": jobs, "total_count": total}))
STUB
cat >"$work/bin/colima" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# Real Colima 0.10.3 preserves stdout but collapses every nonzero exit to 1.
trap 'rc=$?; if [[ "$rc" != 0 ]]; then exit 1; fi' EXIT
[[ "${COLIMA_HOME:-}" == "${XDG_CONFIG_HOME:?}/colima" ]] || exit 88
[[ "${LIMA_HOME:-}" == "$COLIMA_HOME/_lima" ]] || exit 89
printf 'colima %s\n' "$*" >>"$CI_TEST_CALLS"
if [[ "$1" == --profile ]]; then
  if [[ "${CI_TEST_REQUIRE_CLOSED_STDIN:-0}" == 1 ]] && IFS= read -r ignored; then exit 87; fi
  if [[ "${CI_TEST_SSH_FAIL_ONCE:-0}" == 1 && "$*" == *'/host-ready' && ! -e "$CI_VM_STATE_DIR/ssh-failed" ]]; then
    touch "$CI_VM_STATE_DIR/ssh-failed"
    exit 255
  fi
  case "$*" in
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/host-ready')
      if [[ "${CI_TEST_ENROLL_ON_READY:-0}" == 1 ]]; then touch "$CI_VM_STATE_DIR/enrolled"; fi
      exit "${CI_TEST_READY_FAIL:-0}"
      ;;
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/host-ready --provision-only') exit 0 ;;
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/control worker-active')
      if [[ "${CI_TEST_WORKER_NUL:-0}" == 1 ]]; then printf 'CI_VM_STATUS=no-worker\000\n'; exit 0; fi
      if [[ ${CI_TEST_WORKER_OUTPUT+x} ]]; then printf '%s' "$CI_TEST_WORKER_OUTPUT"; exit "${CI_TEST_STATUS_EXIT:-0}"; fi
      case "${CI_TEST_WORKER:-1}" in
      0) printf 'CI_VM_STATUS=worker-busy\n' ;;
      1) printf 'CI_VM_STATUS=no-worker\n' ;;
      2) printf 'CI_VM_STATUS=unknown\n' ;;
      *) exit "$CI_TEST_WORKER" ;;
      esac
      ;;
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/control enrolled')
      if [[ "${CI_TEST_ENROLLED_FAIL:-0}" == 1 ]]; then exit 255; fi
      if [[ ${CI_TEST_ENROLLED_OUTPUT+x} ]]; then printf '%s' "$CI_TEST_ENROLLED_OUTPUT"; exit "${CI_TEST_STATUS_EXIT:-0}"; fi
      if [[ -e "$CI_VM_STATE_DIR/enrolled" ]]; then printf 'CI_VM_STATUS=enrolled:hausnetz\n'; else printf 'CI_VM_STATUS=enrolled:%s\n' "${CI_TEST_ENROLLED:-}"; fi
      ;;
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/control drain')
      if [[ ${CI_TEST_DRAIN_OUTPUT+x} ]]; then printf '%s' "$CI_TEST_DRAIN_OUTPUT"; exit "${CI_TEST_STATUS_EXIT:-0}"; fi
      if [[ "${CI_TEST_WORKER:-1}" == 0 ]]; then printf 'CI_VM_STATUS=worker-busy\n'; exit 0; fi
      case "${CI_TEST_DRAIN:-0}" in
      0) printf 'CI_VM_STATUS=drained\n' ;;
      3) printf 'CI_VM_STATUS=worker-busy\n' ;;
      2) printf 'CI_VM_STATUS=unknown\n' ;;
      *) exit "$CI_TEST_DRAIN" ;;
      esac
      ;;
    *) exit 86 ;;
  esac
  exit 0
fi
[[ "$2" == ci ]] || exit 80
case "$1" in
  status)
    if [[ "$(<"$CI_TEST_VM")" == running ]]; then
      printf '{"status":"Running"}\n'
    else
      printf 'colima [profile=ci] is not running\n' >&2
      exit 1
    fi
    ;;
  start)
    [[ "$*" == 'start ci --activate=false --ssh-config=false' ]] || exit 81
    # A boot without an atomic, complete own lock must fail this contract.
    "$CI_TEST_REAL_JQ" -e '.schema == "mbp2607-heavy-lock.v1" and .owner == "hausnetz-ci-vm" and (.pid | type == "number") and .host == "mbp2607" and (.job_url | startswith("https://"))' "$CI_VM_HEAVY_LOCK/owner.json" >/dev/null || exit 91
    [[ ! -L "$COLIMA_HOME/ci/colima.yaml" ]] || exit 82
    if [[ "${CI_TEST_START_FAIL:-0}" == 1 ]]; then exit 1; fi
    cmp -s "$CI_VM_CONFIG" "$COLIMA_HOME/ci/colima.yaml" || exit 83
    printf '\n# rewritten by Colima\n' >>"$COLIMA_HOME/ci/colima.yaml"
    echo running >"$CI_TEST_VM"
    ;;
  stop)
    if [[ "${CI_TEST_STOP_STAYS_RUNNING:-0}" != 1 ]]; then echo stopped >"$CI_TEST_VM"; fi
    ;;
  *) exit 84 ;;
esac
STUB
cat >"$work/bin/jq" <<'STUB'
#!/usr/bin/env bash
if [[ "${CI_TEST_JQ_FAIL:-}" == offered && "$*" == *'ascii_downcase) | unique'* ]] ||
   [[ "${CI_TEST_JQ_FAIL:-}" == match && "$*" == *'if any(.jobs[];'* ]]; then exit 5; fi
exec "$CI_TEST_REAL_JQ" "$@"
STUB
cat >"$work/bin/trash" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "$CI_VM_STATE_DIR"/secrets/*.token && -f "$1" && ! -L "$1" ]] || exit 1
printf 'trash token\n' >>"$CI_TEST_CALLS"
mkdir -p "$CI_VM_STATE_DIR/trashed"
mv "$1" "$CI_VM_STATE_DIR/trashed/"
STUB
cat >"$work/bin/limactl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${COLIMA_HOME:-}" == "${XDG_CONFIG_HOME:?}/colima" ]] || exit 88
[[ "${LIMA_HOME:-}" == "$COLIMA_HOME/_lima" ]] || exit 89
[[ "$*" == list ]] || exit 90
printf 'limactl %s\n' "$*" >>"$CI_TEST_CALLS"
STUB
cat >"$work/bin/taskpolicy" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected taskpolicy %s\n' "$*" >>"$CI_TEST_CALLS"
exit 85
STUB
cat >"$work/bin/qos" <<'STUB'
#!/usr/bin/env bash
printf 'qos ci\n' >>"$CI_TEST_CALLS"
if [[ "$(<"$CI_TEST_VM")" == running && ( "${CI_TEST_HA_UNKNOWN:-0}" == 1 || "${CI_TEST_HA_ZERO:-0}" == 1 ) ]]; then exit 1; fi
exit "${CI_TEST_QOS_FAIL:-0}"
STUB
cat >"$work/bin/hostagent" <<'STUB'
#!/usr/bin/env bash
[[ "${CI_TEST_HA_LIVE:-0}" == 1 || "$(<"$CI_TEST_VM")" == running ]] || exit 1
[[ "${CI_TEST_HANDOFF_FAIL:-0}" != 1 ]] || exit 1
printf '%s\n' "$CI_TEST_HA_PID"
STUB
cat >"$work/bin/hostagent-state" <<'STUB'
#!/usr/bin/env bash
[[ "${CI_TEST_HA_UNKNOWN:-0}" != 1 ]] || exit 1
if [[ "$(<"$CI_TEST_VM")" == running && "${CI_TEST_HA_ZERO:-0}" == 1 ]]; then
  printf '0\n'
elif [[ "${CI_TEST_HA_LIVE:-0}" == 1 || "$(<"$CI_TEST_VM")" == running ]]; then
  printf '%s\n' "$CI_TEST_HA_PID"
else
  printf '0\n'
fi
STUB
cat >"$work/bin/date" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then printf '%s\n' "$CI_TEST_NOW"; else printf 'fixture-time\n'; fi
STUB
chmod +x "$work/bin/"*

render_host_helper() {
  python3 - "$root/hosts/mbp2607/files/ci-vm/host.py" "$CI_VM_HOST_HELPER" "$CI_VM_STATE_DIR" "$LIMA_HOME/colima-ci/ha.pid" "$1" "$work/bin/qos" <<'PY'
import json
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
for placeholder, value in zip(("@stateDir@", "@pidfile@", "@dispatcher@"), sys.argv[3:6]):
    source = source.replace(json.dumps(placeholder), json.dumps(value))
source = source.replace('QOS_COMMAND = (sys.executable, __file__, "qos", PIDFILE)',
                        'QOS_COMMAND = ' + repr((sys.argv[6],)))
source = source.replace('"hostagent": (sys.executable, __file__, "hostagent"),',
                        '"hostagent": ' + repr((str(Path(sys.argv[6]).with_name("hostagent")),)) + ',')
source = source.replace('"hostagent-state": (sys.executable, __file__, "hostagent-state"),',
                        '"hostagent-state": ' + repr((str(Path(sys.argv[6]).with_name("hostagent-state")),)) + ',')
Path(sys.argv[2]).write_text(source)
PY
}

new_case() {
  case_dir=$(mktemp -d "$work/case.XXXXXXXX")
  mkdir -p "$case_dir/home" "$case_dir/state"
  echo stopped >"$case_dir/vm"
  : >"$case_dir/calls"
  printf 'GH_TOKEN=fixture-agent-value\n' >"$case_dir/agent.env"
  chmod 0600 "$case_dir/agent.env"
  cp "$work/repos.json" "$case_dir/repos.json"
  export HOME="$case_dir/home" PATH="$work/bin:$PATH"
  export XDG_CONFIG_HOME="$HOME/.config"
  export COLIMA_HOME="$XDG_CONFIG_HOME/colima" LIMA_HOME="$XDG_CONFIG_HOME/colima/_lima"
  mkdir -p "$COLIMA_HOME/ci"
  touch "$COLIMA_HOME/ci/.nixcfg-ci-vm"
  export CI_VM_STATE_DIR="$case_dir/state" CI_VM_CONFIG="$work/declared.yaml"
  export CI_VM_REPOSITORIES="$case_dir/repos.json" CI_VM_AGENT_TOKEN_FILE="$case_dir/agent.env"
  export CI_VM_HOST_HELPER="$case_dir/host.py"
  export CI_VM_HEAVY_LOCK="$case_dir/ci-locks/mbp2607-heavy.lock.d"
  export CI_VM_HEAVY_LOCK_HELPER="$case_dir/heavy-lock.py" CI_TEST_HA_PID=$$
  # The fixture invokes the test-only function with its disposable path.
  # Production's CLI has no path argument or environment override.
  python3 - "$root/hosts/mbp2607/files/ci-vm/heavy-lock.py" "$CI_VM_HEAVY_LOCK_HELPER" <<'PY_HEAVY_FIXTURE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text().replace('if __name__ == "__main__":', 'if False:')
source += '\nif __name__ == "__main__":\n    action, pid, now, *extra = sys.argv[1:]\n    print(json.dumps(operate(action, Path(os.environ["CI_VM_HEAVY_LOCK"]), int(pid), int(now), extra[0] if extra else "", int(extra[1]) if len(extra) > 1 else 0)))\n'
Path(sys.argv[2]).write_text(source)
PY_HEAVY_FIXTURE
  export CI_TEST_ISSUE_STATE=open
  export CI_TEST_CANCEL=ok CI_TEST_COMMENT=ok CI_TEST_ISSUE=ok CI_TEST_HANDOFF_FAIL=0 CI_TEST_HA_LIVE=0 CI_TEST_HA_UNKNOWN=0 CI_TEST_HA_ZERO=0 CI_TEST_RUN_ATTEMPT=1
  export CI_TEST_RUN_ID=11 CI_TEST_WORKFLOW=.github/workflows/nix.yml CI_TEST_NIGHTLY=0
  export CI_TEST_SCENARIO=empty CI_TEST_NOW=1000 CI_TEST_CALLS="$case_dir/calls" CI_TEST_VM="$case_dir/vm" CI_TEST_QOS_FAIL=0 CI_TEST_READY_FAIL=0 CI_TEST_REQUIRE_CLOSED_STDIN=0
  export CI_TEST_WORKER=1 CI_TEST_DRAIN=0 CI_TEST_START_FAIL=0 CI_TEST_ENROLLED='' CI_TEST_JQ_FAIL=''
  export CI_TEST_SSH_FAIL_ONCE=0 CI_TEST_ENROLL_ON_READY=0 CI_TEST_ENROLLED_FAIL=0
  export CI_TEST_STATUS_EXIT=0 CI_TEST_STOP_STAYS_RUNNING=0
  export CI_TEST_WORKER_NUL=0
  unset CI_TEST_WORKER_OUTPUT CI_TEST_DRAIN_OUTPUT CI_TEST_ENROLLED_OUTPUT
  render_host_helper "$dispatcher"
}
run_tick() {
  render_host_helper "${1:-$dispatcher}"
  /bin/bash "${1:-$dispatcher}" tick >"$case_dir/out" 2>&1
}
calls() { grep -c "$1" "$case_dir/calls" || true; }
unchanged() { [[ "$(calls 'colima start')" == 0 && "$(calls 'colima stop')" == 0 ]]; }
started() { [[ "$(calls 'colima start')" == 1 && "$(<"$case_dir/vm")" == running ]]; }

new_case
python3 - "$CI_VM_HOST_HELPER" "$dispatcher" "$case_dir" <<'PY'
from pathlib import Path
import subprocess, sys
helper, dispatcher, directory = sys.argv[1:]
lockfile = directory + '/state/dispatcher.lock'
outside = directory + '/unexpected.lock'
for arguments in [
    ['run', '1', '/usr/bin/true'],
    ['run', '1', 'colima', 'stop', 'default'],
    ['run', '1', 'status --json'],
    ['run', 'nan', 'status'],
    ['run', 'inf', 'status'],
    ['run', '0', 'status'],
    ['run', '901', 'status'],
    ['qos', directory + '/unexpected.pid'],
    ['lock', outside, '/bin/bash', dispatcher, '--locked', 'tick'],
    ['lock', lockfile, '/usr/bin/touch', outside],
    ['lock', lockfile, '/bin/bash', dispatcher, '--locked', 'stop', 'default'],
]:
    result = subprocess.run([sys.executable, helper, *arguments], capture_output=True, timeout=5)
    assert result.returncode == 1, arguments
assert not Path(outside).exists() and not Path(lockfile).exists()
PY
[[ ! -s "$case_dir/calls" ]] || fail 'rejected host input reached a CLI stub'
echo 'ok host inputs: arbitrary commands, foreign paths/profiles and invalid deadlines fail before side effects'

python3 - "$root/tests/ci-vm-live-proof.py" "$case_dir" <<'PY'
import ast
from contextlib import nullcontext
import os
from pathlib import Path
import re
import sys
from types import SimpleNamespace
from unittest.mock import patch

# Exercise the actual selectors without executing the live proof's VM calls.
tree = ast.parse(Path(sys.argv[1]).read_text())
nodes = [node for node in tree.body if
         isinstance(node, ast.FunctionDef) and node.name in {'installed_command', 'evidence_path'} or
         isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'EVIDENCE_ROOT' for t in node.targets)]
scope = {'os': os, 'Path': Path, 're': re}
exec(compile(ast.Module(body=nodes, type_ignores=[]), sys.argv[1], 'exec'), scope)

package = '/nix/store/' + 'a' * 32 + '-ci-vm'
entries = [
    SimpleNamespace(name='a' * 32 + '-ci-vm', path=package, is_dir=lambda **kw: not kw['follow_symlinks']),
    SimpleNamespace(name='b' * 32 + '-ci-vm', path='/nix/store/' + 'b' * 32 + '-ci-vm', is_dir=lambda **kw: False),
    SimpleNamespace(name='c' * 32 + '-other', path='/nix/store/' + 'c' * 32 + '-other', is_dir=lambda **kw: True),
]
def installed(root):
    assert root == '/nix/store'
    return nullcontext(entries)

with patch('os.scandir', side_effect=installed):
    assert scope['installed_command'](package + '/bin/ci-vm') == package + '/bin/ci-vm'
    for value in ['/bin/true', package + '/bin/other', '/nix/store/' + 'b' * 32 + '-ci-vm/bin/ci-vm',
                  '/nix/store/' + 'c' * 32 + '-other/bin/ci-vm', package + '/../../tmp/ci-vm']:
        try:
            scope['installed_command'](value)
        except ValueError:
            continue
        raise AssertionError('accepted a command outside the installed ci-vm allowlist')

qa = Path(sys.argv[2]) / 'qa'
qa.mkdir()
outside = Path(sys.argv[2]) / 'qa-other'
outside.mkdir()
(qa / 'escape').symlink_to(outside, target_is_directory=True)
scope['EVIDENCE_ROOT'] = str(qa)
assert scope['evidence_path'](str(qa / 'ops669')) == qa / 'ops669'
for value in [outside, qa / '../qa-other/log', qa / 'escape/log']:
    try:
        scope['evidence_path'](str(value))
    except ValueError:
        continue
    raise AssertionError('evidence escaped through traversal, a sibling prefix or a symlink')
PY
echo 'ok proof inputs: installed-package selection and evidence traversal/sibling/symlink boundaries pass without a VM'

new_case
for cli in colima limactl; do
  args=(list)
  if [[ "$cli" == colima ]]; then args=(status ci --json); fi
  if (
    unset COLIMA_HOME
    "$cli" "${args[@]}"
  ) >"$case_dir/out" 2>&1; then
    fail "$cli stub accepted an unset Colima home"
  fi
  if COLIMA_HOME="$HOME/.colima" "$cli" "${args[@]}" >"$case_dir/out" 2>&1; then
    fail "$cli stub accepted the legacy Colima home"
  fi
  if (
    unset LIMA_HOME
    "$cli" "${args[@]}"
  ) >"$case_dir/out" 2>&1; then
    fail "$cli stub accepted an unset Lima home"
  fi
done
[[ ! -s "$case_dir/calls" ]] || fail 'invalid homes reached a CLI stub'
limactl list
[[ "$(calls 'limactl list')" == 1 ]] || fail 'Lima stub rejected the XDG home'
new_case
if (
  unset COLIMA_HOME
  /bin/bash "$dispatcher" prepare
) >"$case_dir/out" 2>&1; then
  fail 'dispatcher accepted an unset Colima home'
fi
[[ ! -s "$case_dir/calls" && ! -e "$HOME/.colima" ]] || fail 'missing home caused side effects'
echo 'ok homes: every Colima/Lima stub requires the XDG homes; dispatcher refuses a missing home'

new_case
export XDG_CONFIG_HOME="$HOME/custom-xdg"
export COLIMA_HOME="$XDG_CONFIG_HOME/colima" LIMA_HOME="$XDG_CONFIG_HOME/colima/_lima"
export CI_TEST_SCENARIO=queued
run_tick
started && [[ -f "$COLIMA_HOME/ci/colima.yaml" && ! -e "$HOME/.colima" ]] || fail 'custom XDG home was ignored'
echo 'ok custom XDG: ci config and CLI share the explicitly configured home'

for scenario in wrong-arch wrong-host no-labels completed empty foreign-progress; do
  new_case
  export CI_TEST_SCENARIO=$scenario
  run_tick
  unchanged || fail "$scenario booted/stopped ci"
done
echo 'ok labels: all requested labels required, ARM64 and host must match; completed/unlabeled jobs ignored'

new_case
export CI_TEST_SCENARIO=queued
run_tick
started || fail 'matching queued demand did not start ci'
[[ "$(calls 'taskpolicy')" == 0 && "$(calls 'qos ci')" == 1 ]] || fail 'standard-policy enforcement'
[[ "$(<"$case_dir/state/last-demand")" == 1000 ]] || fail 'demand timestamp'
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$case_dir/state/secrets")" == 0o700 ]] || fail 'secret directory mode'
# Start again after Colima rewrote the file: starter must replace it with a copy.
echo stopped >"$case_dir/vm"
run_tick
[[ "$(calls 'colima start')" == 2 ]] || fail 'copied config did not survive a Colima rewrite'
echo 'ok demand: queued jobs start ci under standard QoS; writable config is refreshed for each start'

new_case
printf 'export GH_TOKEN=fixture-agent-value\n' >"$case_dir/agent.env"
export GH_TOKEN=fixture-inherited-value CI_TEST_SCENARIO=queued
run_tick
started || fail 'exported/inherited GH_TOKEN leaked to curl'
unset GH_TOKEN
echo 'ok token environment: even exported/inherited GH_TOKEN never reaches curl'

new_case
echo running >"$case_dir/vm"
echo 1 >"$case_dir/state/last-demand"
export CI_TEST_SCENARIO=progress CI_TEST_NOW=5000
run_tick
unchanged && [[ "$(<"$case_dir/state/last-demand")" == 5000 ]] || fail 'in-progress job failed to retain ci'
echo 'ok active: in-progress jobs reset grace without restarting ci'

active_ssh_contract() {
  new_case
  echo running >"$case_dir/vm"
  export CI_TEST_SCENARIO=progress CI_TEST_SSH_FAIL_ONCE=1 CI_TEST_ENROLLED=hausnetz
  if run_tick "$1"; then fail 'single SSH failure passed readiness'; fi
  unchanged || return 1
  [[ "$(calls 'control drain')" == 0 && "$(calls 'control enrolled')" == 0 && "$(calls '/actions/runners?')" == 0 ]] || return 1
  grep -q 'retrying next tick' "$case_dir/out" || return 1
  export CI_TEST_NOW=1060
  run_tick "$1"
  unchanged && [[ "$(calls '/host-ready')" == 2 ]]
}
active_ssh_contract "$dispatcher" || fail 'single SSH failure stopped an API-active job or prevented the next tick retry'
for failure in ready enrolled stale; do
  new_case
  echo running >"$case_dir/vm"
  export CI_TEST_SCENARIO=queued CI_TEST_WORKER=0 CI_TEST_ENROLLED=hausnetz
  case "$failure" in
  ready) export CI_TEST_READY_FAIL=1 ;;
  enrolled) export CI_TEST_ENROLLED_FAIL=1 ;;
  stale) export CI_TEST_SCENARIO=stale-runner ;;
  esac
  if run_tick; then [[ "$failure" != ready ]] || fail 'failed readiness passed'; fi
  unchanged && [[ "$(calls 'control enrolled')" == 0 && "$(calls '/actions/runners?')" == 0 ]] || fail "$failure disturbed a local worker"
done
new_case
echo running >"$case_dir/vm"
export CI_TEST_SCENARIO=queued CI_TEST_READY_FAIL=1 CI_TEST_DRAIN=3
if run_tick; then fail 'failed readiness passed'; fi
unchanged && [[ "$(calls 'control drain')" == 1 ]] || fail 'reactivation failure skipped drain or killed a newly assigned worker'
new_case
echo running >"$case_dir/vm"
export CI_TEST_SCENARIO=queued CI_TEST_READY_FAIL=1
if run_tick; then fail 'failed readiness passed'; fi
[[ "$(calls 'control drain')" == 1 && "$(calls 'colima stop')" == 1 ]] || fail 'idle reactivation failure did not drain before stop'
new_case
echo running >"$case_dir/vm"
export CI_TEST_SCENARIO=progress CI_TEST_WORKER=0 CI_TEST_QOS_FAIL=1
if run_tick; then fail 'QoS failure passed'; fi
[[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 0 ]] || fail 'QoS failure retained an unsafe active VM'
echo 'ok reactivation: transient failures retain API/local work, idle failures drain, and QoS failures stop immediately'

new_case
echo running >"$case_dir/vm"
export CI_TEST_REQUIRE_CLOSED_STDIN=1
printf 'caller input must not reach guest SSH\n' | /bin/bash "$dispatcher" start >"$case_dir/out" 2>&1
unchanged && [[ "$(calls 'host-ready')" == 1 ]] || fail 'manual start did not retry readiness on a running VM'
echo 'ok enrollment retry: manual start activates runners on running ci without forwarding caller stdin'

for scenario in job-pages run-pages multiple mixed; do
  new_case
  if [[ "$scenario" == multiple || "$scenario" == mixed ]]; then
    jq '. + [{id:"extra", repository:"inspr-at/extra", runnerName:"mbp2607-extra", labels:["mbp2607","extra","kvm"]}]' "$work/repos.json" >"$case_dir/repos.json"
  fi
  export CI_TEST_SCENARIO=$scenario
  run_tick
  started || fail "$scenario demand missed"
done
echo 'ok coverage: paginated runs/jobs, multiple repos, known demand despite another repo API failure'

new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/last-demand"
export CI_TEST_NOW=2199
run_tick
unchanged || fail 'stopped before 20-minute grace'
export CI_TEST_NOW=2200
run_tick
[[ "$(calls 'colima stop')" == 1 && "$(<"$case_dir/vm")" == stopped ]] || fail 'did not stop at 20-minute grace'
echo 'ok idle: retains ci at 1199 s, stops at 1200 s'

for scenario in failure malformed malformed-jobs truncated short-runs short-jobs negative-count huge-count missing-token; do
  new_case
  echo running >"$case_dir/vm"
  echo 1 >"$case_dir/state/last-demand"
  export CI_TEST_SCENARIO=$scenario CI_TEST_NOW=5000
  if [[ "$scenario" == missing-token ]]; then export CI_VM_AGENT_TOKEN_FILE="$case_dir/absent.env"; fi
  run_tick
  unchanged && [[ "$(<"$case_dir/state/last-demand")" == 1 ]] || fail "$scenario reset actual-demand timestamp"
  [[ "$(<"$case_dir/state/unknown-since")" == 5000 ]] || fail "$scenario lost unknown-state timer"
  export CI_TEST_NOW=6199
  run_tick
  unchanged || fail "$scenario stopped before 20 minutes without work"
  export CI_TEST_NOW=6200
  run_tick
  [[ "$(calls 'colima stop')" == 1 ]] || fail "$scenario ran indefinitely without a worker"
done
new_case
echo running >"$case_dir/vm"
export CI_TEST_SCENARIO=failure CI_TEST_WORKER=0
run_tick
for time in 2000 3000 4599; do
  export CI_TEST_NOW=$time
  run_tick
  unchanged || fail 'unknown-state cap interrupted local work too early'
done
export CI_TEST_NOW=4600
run_tick
[[ "$(calls 'colima stop')" == 1 ]] || fail 'unknown-state worker bypassed absolute 60-minute cap'
echo 'ok uncertainty: API/auth/schema/missing-token errors stop after 20 minutes without a worker; active workers have a 60-minute absolute cap'

new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/unknown-since"
echo 1000 >"$case_dir/state/no-worker-since"
export CI_TEST_SCENARIO=failure CI_TEST_WORKER=124 CI_TEST_DRAIN=124 CI_TEST_NOW=2200
run_tick
[[ "$(calls 'colima stop')" == 1 ]] || fail 'unreachable worker/drain bypassed uptime bound'

for part in offered match; do
  new_case
  export CI_TEST_SCENARIO=queued CI_TEST_JQ_FAIL=$part
  run_tick
  unchanged || fail "unchecked $part jq failure changed VM state"
  grep -q 'demand unknown' "$case_dir/out" || fail "unchecked $part jq failure"
done
echo 'ok parsing: expression failures inside a conditional demand scan stay unknown'

new_case
export CI_TEST_SCENARIO=queued
run_tick
export CI_TEST_NOW=1599
run_tick
[[ "$(calls 'colima stop')" == 0 ]] || fail 'queued demand stopped too early'
export CI_TEST_NOW=1600
run_tick
[[ "$(calls 'colima stop')" == 1 ]] || fail 'unservable queue kept ci up'
grep -q 'UNSERVABLE' "$case_dir/out" || fail 'unservable queue not reported'
export CI_TEST_NOW=1660
run_tick
[[ "$(calls 'colima start')" == 1 ]] || fail 'unservable queue ignored backoff'
echo 'ok queued demand: no pickup for 10 minutes stops ci and backs off'

new_case
echo running >"$case_dir/vm"
echo 1 >"$case_dir/state/last-demand"
export CI_TEST_NOW=5000 CI_TEST_DRAIN=3
run_tick
unchanged || fail 'drain race killed a newly assigned job'
echo 'ok drain: a worker found after the API scan prevents idle shutdown'

worker_cap_contract() {
  new_case
  echo running >"$case_dir/vm"
  export CI_TEST_SCENARIO="$2" CI_TEST_WORKER=0
  run_tick "$1"
  [[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 1000 ]] || return 1
  export CI_TEST_NOW=4599
  run_tick "$1"
  unchanged || return 1
  export CI_TEST_NOW=4600
  run_tick "$1"
  [[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 0 ]]
}
for scenario in empty queued; do
  worker_cap_contract "$dispatcher" "$scenario" || fail "$scenario local worker bypassed the absolute 60-minute cap"
done
new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/worker-without-api-demand-since"
export CI_TEST_SCENARIO=progress CI_TEST_WORKER=0 CI_TEST_NOW=4600
run_tick
unchanged && [[ ! -s "$case_dir/state/worker-without-api-demand-since" ]] || fail 'API-confirmed active work did not clear the local-only cap'
export CI_TEST_SCENARIO=empty CI_TEST_NOW=5000
run_tick
[[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 5000 ]] || fail 'local-only cap failed to restart after API-confirmed work'
export CI_TEST_WORKER=1 CI_TEST_NOW=5100
run_tick
[[ ! -s "$case_dir/state/worker-without-api-demand-since" ]] || fail 'confirmed worker exit did not clear the local-only cap'
new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/worker-without-api-demand-since"
export CI_TEST_SCENARIO=queued CI_TEST_WORKER=124 CI_TEST_NOW=4599
run_tick
[[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 1000 ]] || fail 'SSH uncertainty reset the absolute local-worker cap'
export CI_TEST_NOW=4600
run_tick
[[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 0 ]] || fail 'SSH uncertainty bypassed the absolute local-worker cap'
new_case
echo running >"$case_dir/vm"
echo 1 >"$case_dir/state/last-demand"
export CI_TEST_DRAIN=3 CI_TEST_NOW=5000
run_tick
[[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 5000 ]] || fail 'drain worker did not start the absolute local-only cap'
export CI_TEST_NOW=8600
run_tick
[[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 1 ]] || fail 'drain worker bypassed the absolute local-only cap'
new_case
echo running >"$case_dir/vm"
export CI_TEST_WORKER=0
if /bin/bash "$dispatcher" stop >"$case_dir/out" 2>&1; then fail 'normal operator stop ignored a worker'; else rc=$?; fi
[[ "$rc" == 3 && "$(calls 'colima stop')" == 0 ]] || fail 'normal operator stop failed to retain work'
export CI_TEST_NOW=4600
/bin/bash "$dispatcher" stop >"$case_dir/out" 2>&1
[[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 1 ]] || fail 'operator stop could not enforce the expired worker cap'
new_case
echo running >"$case_dir/vm"
export CI_TEST_WORKER=0
/bin/bash "$dispatcher" stop --force >"$case_dir/out" 2>&1
[[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 0 ]] || fail 'explicit force stop did not skip drain'
echo 'ok local-only work: known-idle/queued/drain workers have an absolute 60-minute cap; operator stop enforces it and supports --force'

status_protocol_contract() {
  new_case
  echo running >"$case_dir/vm"
  echo 1000 >"$case_dir/state/worker-without-api-demand-since"
  export CI_TEST_NOW=1059
  run_tick "$1"
  [[ ! -s "$case_dir/state/worker-without-api-demand-since" ]] || return 1
  new_case
  echo running >"$case_dir/vm"
  export CI_TEST_WORKER=0
  render_host_helper "$1"
  if /bin/bash "$1" stop >"$case_dir/out" 2>&1; then return 1; else rc=$?; fi
  [[ "$rc" == 3 && "$(calls 'colima stop')" == 0 ]]
}
status_protocol_contract "$dispatcher" || fail 'stdout status protocol failed verified-exit or drain-busy contract'
for output in '' $'CI_VM_STATUS=no-worker' $'CI_VM_STATUS=no-worker\n\n' \
  $'noise\nCI_VM_STATUS=no-worker\n' $'CI_VM_STATUS=no-worker\nCI_VM_STATUS=worker-busy\n' \
  $'CI_VM_STATUS=drained\n' $'CI_VM_STATUS=unknown\n'; do
  new_case
  echo running >"$case_dir/vm"
  echo 1000 >"$case_dir/state/worker-without-api-demand-since"
  export CI_TEST_WORKER_OUTPUT="$output" CI_TEST_NOW=4599
  run_tick
  [[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 1000 ]] || fail 'missing/malformed worker record cleared the local-worker cap'
  export CI_TEST_NOW=4600
  run_tick
  [[ "$(calls 'colima stop')" == 1 && "$(calls 'control drain')" == 0 ]] || fail 'unknown worker record bypassed the absolute cap'
done
new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/worker-without-api-demand-since"
export CI_TEST_WORKER_NUL=1 CI_TEST_NOW=4599
run_tick
[[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 1000 ]] || fail 'NUL-corrupted worker record counted as verified exit'
for code in 2 3 255; do
  new_case
  export CI_TEST_WORKER_OUTPUT=$'CI_VM_STATUS=no-worker\n' CI_TEST_STATUS_EXIT=$code
  if colima --profile ci ssh -- sudo /usr/local/libexec/ci-vm/control worker-active >"$case_dir/out"; then fail 'stub lost transport failure'; else rc=$?; fi
  [[ "$rc" == 1 && "$(<"$case_dir/out")" == 'CI_VM_STATUS=no-worker' ]] || fail 'stub did not preserve stdout and collapse nonzero status'
  echo running >"$case_dir/vm"
  echo 1000 >"$case_dir/state/worker-without-api-demand-since"
  export CI_TEST_NOW=4599
  run_tick
  [[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 1000 ]] || fail 'failed SSH with a valid stdout token cleared the cap'
done
for code in 2 255; do
  new_case
  echo running >"$case_dir/vm"
  echo 1000 >"$case_dir/state/worker-without-api-demand-since"
  export CI_TEST_WORKER=$code CI_TEST_NOW=4599
  run_tick
  [[ "$(<"$case_dir/state/worker-without-api-demand-since")" == 1000 ]] || fail 'guest unknown/SSH failure counted as verified worker exit'
done
for output in '' $'hausnetz\n' $'CI_VM_STATUS=enrolled:foreign\n' \
  $'CI_VM_STATUS=enrolled:hausnetz,hausnetz\n' $'CI_VM_STATUS=enrolled:hausnetz\n\n' \
  $'CI_VM_STATUS=unknown\n'; do
  new_case
  mkdir -p "$CI_VM_STATE_DIR/secrets"
  printf 'fixture-registration-value\n' >"$CI_VM_STATE_DIR/secrets/hausnetz.token"
  export CI_TEST_SCENARIO=queued CI_TEST_ENROLLED_OUTPUT="$output"
  if run_tick; then fail 'invalid enrollment record passed activation'; fi
  [[ "$(calls 'trash token')" == 0 && "$(calls '/actions/runners?')" == 0 ]] || fail 'invalid enrollment record reached maintenance'
done
new_case
export CI_TEST_SCENARIO=queued CI_TEST_ENROLLED=extra,hausnetz
jq '. + [{id:"extra", repository:"inspr-at/extra", runnerName:"mbp2607-extra", labels:["mbp2607","extra","kvm"]}]' "$work/repos.json" >"$case_dir/repos.json"
run_tick
[[ "$(calls '/actions/runners?')" == 2 ]] || fail 'valid multi-repo enrollment record lost a repository'
new_case
echo running >"$case_dir/vm"
echo 1 >"$case_dir/state/last-demand"
export CI_TEST_NOW=5000 CI_TEST_DRAIN_OUTPUT=$'CI_VM_STATUS=worker-busy\nextra\n'
run_tick
[[ "$(calls 'colima stop')" == 1 ]] || fail 'unknown drain record bypassed shutdown bound'
grep -q 'guest drain unavailable' "$case_dir/out" || fail 'malformed drain record was not unknown'
echo 'ok status protocol: collapsed nonzero exits, exact stdout records, transport failures, cap preservation and validated enrollment'

for value in missing corrupt 9999999; do
  new_case
  echo running >"$case_dir/vm"
  if [[ "$value" != missing ]]; then echo "$value" >"$case_dir/state/last-demand"; fi
  run_tick
  unchanged && [[ "$(<"$case_dir/state/last-demand")" == 1000 ]] || fail "$value clock/state recovery"
done
echo 'ok recovery: absent/corrupt/future timestamps begin a fresh grace period'

for failure in qos ready start; do
  new_case
  export CI_TEST_SCENARIO=queued
  case "$failure" in
  qos) export CI_TEST_QOS_FAIL=1 ;;
  ready) export CI_TEST_READY_FAIL=1 ;;
  start) export CI_TEST_START_FAIL=1 ;;
  esac
  if run_tick; then fail "$failure failure passed"; fi
  [[ "$(calls 'colima start')" == 1 && "$(calls 'colima stop')" == 1 ]] || fail "$failure failure left ci running"
  [[ "$(<"$case_dir/state/backoff")" == '1 1060' ]] || fail "$failure failure not persisted"
  export CI_TEST_NOW=1059
  run_tick
  [[ "$(calls 'colima start')" == 1 ]] || fail "$failure failure booted again before backoff"
  export CI_TEST_NOW=1060
  if run_tick; then fail "$failure retry failure passed"; fi
  [[ "$(<"$case_dir/state/backoff")" == '2 1180' ]] || fail "$failure backoff did not double"
done
echo 'ok failures: start/QoS/readiness failures persist and double retry backoff'

new_case
echo running >"$case_dir/vm"
export CI_TEST_QOS_FAIL=1
if run_tick; then fail 'running VM with failed standard policy passed'; fi
[[ "$(calls 'colima stop')" == 1 && "$(calls 'host-ready')" == 0 ]] || fail 'failed standard policy retained ci or opened the guest gate'
grep -q 'standard policy could not be verified' "$case_dir/out" || fail 'standard policy failure was not reported'
echo 'ok standard-policy failure: running ci stops before guest readiness'

new_case
export CI_TEST_SCENARIO=stale-runner CI_TEST_ENROLLED=hausnetz
if run_tick; then fail 'stale local enrollment passed'; fi
grep -q 'needs re-enrollment' "$case_dir/out" || fail 'stale enrollment not reported'
[[ "$(calls 'colima stop')" == 1 && "$(<"$case_dir/state/backoff")" == '1 4600' ]] || fail 'stale enrollment loop not contained'

for ready_failure in 0 1; do
  new_case
  mkdir -p "$CI_VM_STATE_DIR/secrets"
  printf 'fixture-registration-value\n' >"$CI_VM_STATE_DIR/secrets/hausnetz.token"
  chmod 0600 "$CI_VM_STATE_DIR/secrets/hausnetz.token"
  export CI_TEST_SCENARIO=queued CI_TEST_ENROLLED=hausnetz CI_TEST_READY_FAIL=$ready_failure
  if run_tick; then [[ "$ready_failure" == 0 ]] || fail 'failed ready passed'; fi
  [[ ! -e "$CI_VM_STATE_DIR/secrets/hausnetz.token" && "$(calls 'trash token')" == 1 ]] || fail 'enrolled runner retained host token'
  [[ "$(calls 'control enrolled')" == 1 && "$(calls '/actions/runners?')" == 1 ]] || fail 'enrollment was fetched more than once'
done
new_case
mkdir -p "$CI_VM_STATE_DIR/secrets"
printf 'fixture-registration-value\n' >"$CI_VM_STATE_DIR/secrets/hausnetz.token"
export CI_TEST_SCENARIO=queued CI_TEST_ENROLL_ON_READY=1
run_tick
[[ "$(calls 'trash token')" == 1 && "$(calls 'control enrolled')" == 1 ]] || fail 'new enrollment did not retire its token in the same tick'
echo 'ok enrollment: stale .runner requires re-enrollment; host trashes token once .runner exists, including after a later service failure'

new_case
export CI_TEST_READY_FAIL=1
/bin/bash "$dispatcher" start --provision-only >"$case_dir/out" 2>&1
started && [[ "$(calls 'host-ready --provision-only')" == 1 ]] || fail 'provision-only inspection tried to activate a runner'

new_case
mkdir -p "$COLIMA_HOME/ci"
mv "$COLIMA_HOME/ci/.nixcfg-ci-vm" "$case_dir/owned-marker"
echo unrelated >"$COLIMA_HOME/ci/colima.yaml"
export CI_TEST_SCENARIO=queued
if run_tick; then fail 'unowned ci profile was adopted'; fi
unchanged && [[ "$(<"$COLIMA_HOME/ci/colima.yaml")" == unrelated ]] || fail 'unowned profile modified'
echo 'ok containment: failed QoS/provisioning stops only ci; unowned ci data is refused'

new_case
export CI_TEST_SCENARIO=queued
python3 - "$dispatcher" <<'PY'
import fcntl, os, subprocess, sys
with open(os.environ['CI_VM_STATE_DIR'] + '/dispatcher.lock', 'w') as f:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    subprocess.run(['/bin/bash', sys.argv[1], 'tick'], check=True, stdout=subprocess.DEVNULL)
PY
[[ ! -s "$case_dir/calls" ]] || fail 'concurrent tick ignored lock'
run_tick
started || fail 'lock remained stale after owner exited'
echo 'ok locking: concurrent invocation is skipped; lock releases without stale PID files'

new_case
export CI_TEST_SCENARIO=queued
python3 - "$dispatcher" <<'PY'
import os, signal, subprocess, sys
helper = os.environ['CI_VM_HOST_HELPER']
code = 'import subprocess,sys; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"], close_fds=False, stdout=subprocess.DEVNULL); print(p.pid)'
lockfile = os.environ['CI_VM_STATE_DIR'] + '/dispatcher.lock'
exercise = f'import runpy,sys; helper=runpy.run_path({helper!r}); sys.exit(helper["lock"]({lockfile!r}, [sys.executable,"-c",{code!r}]))'
child = int(subprocess.check_output([sys.executable, '-c', exercise], text=True))
try:
    subprocess.run(['/bin/bash', sys.argv[1], 'tick'], check=True, stdout=subprocess.DEVNULL)
    with open(os.environ['CI_TEST_CALLS']) as f:
        assert 'colima start ci ' in f.read(), 'detached daemon inherited dispatcher lock'
finally:
    os.kill(child, signal.SIGTERM)
PY
echo 'ok detached daemon: a surviving child cannot retain the dispatcher lock'

# Shared lock integration contracts, using only disposable fixtures.
heavy_owner() {
  python3 - "$CI_VM_HEAVY_LOCK" "$1" "$2" "${3:-1000}" <<'PY'
import datetime, json
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.mkdir(parents=True, exist_ok=True)
started = datetime.datetime.fromtimestamp(int(sys.argv[4]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
(path / "owner.json").write_text(json.dumps(dict(schema="mbp2607-heavy-lock.v1", owner=sys.argv[2], pid=int(sys.argv[3]), started_at=started, job_url="https://example.test/papp/1", host="mbp2607")))
PY
}
acquire_contract() {
  new_case
  export CI_TEST_SCENARIO=queued
  run_tick "${1:-$dispatcher}" || return 1
  started || return 1
  # $pid is a jq variable.
  # shellcheck disable=SC2016
  "$CI_TEST_REAL_JQ" -e --argjson pid "$$" '.pid == $pid and .job_url == "https://github.com/inspr-at/hausnetz/actions/runs/11"' "$CI_VM_HEAVY_LOCK/owner.json" >/dev/null || return 1
  grep -q 'heavy lock acquired' "$case_dir/out" || return 1
}
acquire_contract || fail 'lock was not acquired before boot and handed to hostagent'
echo 'ok heavy acquire: mkdir and complete owner schema before boot; verified hostagent handoff'

new_case
heavy_owner hausnetz-ci-vm "$$"
echo running >"$case_dir/vm"
cp "$CI_VM_HEAVY_LOCK/owner.json" "$case_dir/owner-before.json"
export CI_TEST_SCENARIO=queued
run_tick
cmp -s "$CI_VM_HEAVY_LOCK/owner.json" "$case_dir/owner-before.json" || fail 'already-running VM rewrote lock'
[[ "$(calls 'colima start')" == 0 ]] || fail 'running VM booted again'
echo 'ok heavy already-running: lock remains byte-identical'

busy_pr_contract() {
  local script=${1:-$dispatcher}
  new_case
  heavy_owner papp-night "$$"
  export CI_TEST_SCENARIO=queued
  run_tick "$script" || return 1
  unchanged || return 1
  export CI_TEST_NOW=1599
  run_tick "$script" || return 1
  [[ "$(calls 'POST .*cancel')" == 0 ]] || return 1
  export CI_TEST_NOW=1600
  run_tick "$script" || return 1
  [[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*issues/42/comments')" == 1 ]] || return 1
  grep -q 'heavy lock cancelled run=11' "$case_dir/out" || return 1
  run_tick "$script" || return 1
  [[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*issues/42/comments')" == 1 ]] || return 1
  # Even after another full wait interval, a confirmed cancel stays terminal.
  export CI_TEST_NOW=2200
  run_tick "$script" || return 1
  [[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*issues/42/comments')" == 1 ]] || return 1
  unchanged || return 1
}
busy_pr_contract || fail 'busy PR wait/cancel/comment/exactly-once contract'
echo 'ok heavy busy PR: waits 10 minutes across ticks, cancels and comments on PR once'

new_case
heavy_owner papp-night "$$"
export CI_TEST_SCENARIO=queued CI_TEST_NIGHTLY=1 CI_TEST_WORKFLOW=.github/workflows/nightly.yml
run_tick
export CI_TEST_NOW=3699
run_tick
[[ "$(calls 'POST .*cancel')" == 0 ]] || fail 'nightly cancelled before 45 minutes'
export CI_TEST_NOW=3700
run_tick
[[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*issues/429/comments')" == 1 && "$(calls 'POST .*/issues$')" == 1 ]] || fail 'nightly cancel did not create and comment on fixed issue'
run_tick
export CI_TEST_RUN_ID=12
run_tick
export CI_TEST_NOW=6400
run_tick
[[ "$(calls 'POST .*cancel')" == 2 && "$(calls 'POST .*issues/429/comments')" == 2 && "$(calls 'POST .*/issues$')" == 1 ]] || fail 'nightly issue was not reused'
unchanged || fail 'busy nightly booted the VM'
echo 'ok heavy nightly: 45-minute boundary, one issue creation, reuse and one comment per run'

new_case
heavy_owner papp-night "$$"
export CI_TEST_SCENARIO=queued CI_TEST_NIGHTLY=1 CI_TEST_WORKFLOW=.github/workflows/other.yml
run_tick
export CI_TEST_NOW=1600
run_tick
[[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*issues/429/comments')" == 1 ]] || fail 'other workflow did not use 10-minute fallback and issue comment'

new_case
heavy_owner hausnetz-ci-vm 99999999
run_tick
[[ ! -d "$CI_VM_HEAVY_LOCK" ]] || fail 'own residue retained while stopped'
grep -q 'heavy lock residue-released' "$case_dir/out" || fail 'residue release not logged'
new_case
heavy_owner hausnetz-ci-vm 99999999
echo running >"$case_dir/vm"
run_tick
[[ -d "$CI_VM_HEAVY_LOCK" ]] || fail 'own residue released while VM runs'
echo 'ok heavy residue: releases only own stopped work, retains lock while running'

new_case
heavy_owner hausnetz-ci-vm "$$"
echo running >"$case_dir/vm"
echo 1000 >"$CI_VM_STATE_DIR/last-demand"
export CI_TEST_NOW=2200
run_tick
[[ ! -d "$CI_VM_HEAVY_LOCK" && -d "${CI_VM_HEAVY_LOCK%/*}" ]] || fail 'idle stop retained lock or removed parent'
grep -q 'heavy lock released' "$case_dir/out" || fail 'idle release not logged'
new_case
export CI_TEST_SCENARIO=queued CI_TEST_START_FAIL=1
if run_tick; then fail 'failed boot returned success'; fi
[[ ! -d "$CI_VM_HEAVY_LOCK" ]] || fail 'boot failure retained lock'
new_case
heavy_owner papp-night "$$"
echo running >"$case_dir/vm"
/bin/bash "$dispatcher" stop --force >"$case_dir/out" 2>&1
[[ -d "$CI_VM_HEAVY_LOCK" ]] || fail 'operator stop released foreign lock'
new_case
heavy_owner hausnetz-ci-vm "$$"
echo running >"$case_dir/vm"
/bin/bash "$dispatcher" stop --force >"$case_dir/out" 2>&1
[[ ! -d "$CI_VM_HEAVY_LOCK" ]] || fail 'operator stop retained own lock'
new_case
heavy_owner hausnetz-ci-vm "$$"
echo running >"$case_dir/vm"
export CI_TEST_STOP_STAYS_RUNNING=1
if /bin/bash "$dispatcher" stop --force >"$case_dir/out" 2>&1; then fail 'unverified stop returned success'; fi
[[ -d "$CI_VM_HEAVY_LOCK" ]] || fail 'still-running VM lost its lock after unsuccessful stop'
echo 'ok heavy release: idle stop, failed boot and operator stop release only own lock; parent retained'

retain_failure_contract() {
  local script=${1:-$dispatcher} action=${2:-tick} kind
  for kind in unknown zero zero-live; do
    new_case
    heavy_owner hausnetz-ci-vm "$$"
    echo running >"$case_dir/vm"
    echo 1000 >"$CI_VM_STATE_DIR/last-demand"
    export CI_TEST_NOW=2200
    if [[ "$kind" == unknown ]]; then export CI_TEST_HA_UNKNOWN=1; else export CI_TEST_HA_ZERO=1; fi
    if [[ "$kind" == zero-live ]]; then export CI_TEST_HA_LIVE=1; fi
    render_host_helper "$script"
    if /bin/bash "$script" "$action" >"$case_dir/out" 2>&1; then return 1; fi
    [[ "$(calls 'qos ci')" == 1 && "$(calls 'colima stop')" == 1 && "$(<"$case_dir/vm")" == stopped ]] || return 1
    grep -q 'ERROR: heavy lock retain failed:' "$case_dir/out" || return 1
    if [[ "$kind" == zero ]]; then
      [[ ! -d "$CI_VM_HEAVY_LOCK" ]] || return 1
      grep -q 'heavy lock released' "$case_dir/out" || return 1
    else
      [[ -f "$CI_VM_HEAVY_LOCK/owner.json" ]] || return 1
      ! grep -q 'heavy lock released' "$case_dir/out" || return 1
      # A later tick can release residue once absence is actually verified.
      export CI_TEST_HA_UNKNOWN=0 CI_TEST_HA_LIVE=0 CI_TEST_HA_ZERO=0
      run_tick "$script" || return 1
      [[ ! -d "$CI_VM_HEAVY_LOCK" ]] || return 1
    fi
  done
}
retain_failure_contract || fail 'retain failure skipped tick health/stop checks or released an unverified holder'
retain_failure_contract "$dispatcher" start || fail 'retain failure skipped start health/stop checks or released an unverified holder'
echo 'ok heavy retain failure: tick and start reach QoS and stop for unknown/zero hostagent; release only after stopped and no live hostagent'

new_case
heavy_owner papp-night "$$"
chmod 000 "$CI_VM_HEAVY_LOCK/owner.json"
export CI_TEST_SCENARIO=queued
run_tick
export CI_TEST_NOW=1600
run_tick
[[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*issues/42/comments')" == 1 ]] || fail 'unreadable lock did not use normal busy cancellation'
unchanged || fail 'unreadable lock booted VM'
[[ -f "$CI_VM_HEAVY_LOCK/owner.json" ]] || fail 'unreadable lock was removed'
grep -q 'COMMENT .*lock I/O failed (PermissionError); operator inspection required' "$case_dir/calls" || fail 'unreadable lock comment hid the inspection cause'
chmod 644 "$CI_VM_HEAVY_LOCK/owner.json"
echo 'ok heavy unreadable record: busy wait and visible cancellation apply; no boot or stale break'

new_case
mkdir -p "${CI_VM_HEAVY_LOCK%/*}"
touch "${CI_VM_HEAVY_LOCK}.blocked"
export CI_TEST_SCENARIO=queued
run_tick
export CI_TEST_NOW=1600
run_tick
unchanged || fail 'blocked recovery booted VM'
grep -q 'COMMENT .*lock recovery blocked by .blocked marker; operator inspection required' "$case_dir/calls" || fail 'blocked lock comment hid the recovery cause'
echo 'ok heavy busy diagnostics: unreadable and blocked locks include actionable causes in cancellation comments'

failed_boot_hostagent_contract() {
  new_case
  export CI_TEST_SCENARIO=queued CI_TEST_START_FAIL=1 CI_TEST_HA_LIVE=1
  if run_tick "${1:-$dispatcher}"; then return 1; fi
  [[ -d "$CI_VM_HEAVY_LOCK" ]] || return 1
  ! grep -q 'heavy lock released' "$case_dir/out"
}
failed_boot_hostagent_contract || fail 'failed boot released a live hostagent lock'
echo 'ok heavy failed boot: live hostagent retains tick lock despite stopped Colima status'

for holder in missing dead-tick; do
  new_case
  if [[ "$holder" == dead-tick ]]; then heavy_owner hausnetz-ci-vm 99999999; fi
  echo running >"$case_dir/vm"
  export CI_TEST_SCENARIO=queued
  run_tick
  # $pid is a jq variable.
  # shellcheck disable=SC2016
  "$CI_TEST_REAL_JQ" -e --argjson pid "$$" '.pid == $pid and .owner == "hausnetz-ci-vm"' "$CI_VM_HEAVY_LOCK/owner.json" >/dev/null || fail 'running hostagent lock not reasserted'
  [[ "$(calls 'colima start')" == 0 ]] || fail 'running lock recovery restarted VM'
done
echo 'ok heavy running recovery: missing lock and dead tick holder reassert the verified hostagent'

# Fix-round contracts run against both the real dispatcher and must-fail copies.
unknown_busy_contract() {
  local script=${1:-$dispatcher} scenario
  for scenario in failure malformed mixed; do
    new_case
    heavy_owner papp-night "$$"
    jq '. + [{id:"extra",repository:"inspr-at/extra",runnerName:"mbp2607-extra",labels:["mbp2607","extra","kvm"]}]' "$work/repos.json" >"$case_dir/repos.json"
    export CI_TEST_SCENARIO=queued
    run_tick "$script" || return 1
    export CI_TEST_SCENARIO=$scenario CI_TEST_NOW=1600
    run_tick "$script" || return 1
    [[ "$(calls 'POST .*cancel')" == 0 && "$(calls 'POST .*comments')" == 0 ]] || return 1
    unchanged || return 1
  done
}
unknown_busy_contract || fail 'unknown/failed/partial busy scan cancelled a run'
echo 'ok heavy unknown scan: failed, malformed and partially successful scans never cancel'

uncertain_cancel_contract() {
  local script=${1:-$dispatcher} tick
  new_case
  heavy_owner papp-night "$$"
  export CI_TEST_SCENARIO=queued CI_TEST_CANCEL=timeout
  run_tick "$script" || return 1
  for tick in 1600 1660 1720 1780; do
    export CI_TEST_NOW=$tick
    run_tick "$script" || return 1
    if [[ "$tick" == 1600 ]]; then
      [[ ! -e "$CI_VM_STATE_DIR/heavy-wait-inspr-at-hausnetz-11-1.cancel-attempted" ]] || return 1
    fi
  done
  [[ "$(calls 'POST .*cancel')" == 3 && "$(calls 'POST .*comments')" == 0 ]] || return 1
  [[ -e "$CI_VM_STATE_DIR/heavy-wait-inspr-at-hausnetz-11-1.cancel_uncertain" ]] || return 1
}
uncertain_cancel_contract || fail 'uncertain cancel was not bounded or falsely commented'
echo 'ok heavy uncertain cancellation: three transport retries, then uncertain marker; no attempted marker after first timeout and no comment'

forbidden_cancel_contract() {
  local script=${1:-$dispatcher}
  new_case
  heavy_owner papp-night "$$"
  export CI_TEST_SCENARIO=queued CI_TEST_CANCEL=403
  run_tick "$script" || return 1
  export CI_TEST_NOW=1600
  run_tick "$script" || return 1
  grep -q 'cancel_failed run=11 HTTP 403' "$case_dir/out" || return 1
  run_tick "$script" || return 1
  ! grep -q 'cancel_failed run=11' "$case_dir/out" || return 1
  [[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*comments')" == 0 ]] || return 1
  [[ -e "$CI_VM_STATE_DIR/heavy-wait-inspr-at-hausnetz-11-1.cancel_failed" ]] || return 1
}
forbidden_cancel_contract || fail 'HTTP 403 cancellation outcome was misreported or repeated'
echo 'ok heavy 403 cancellation: one cancel_failed error with status, no comment and no repeated cancellation'

for comment_outcome in timeout 403; do
  new_case
  heavy_owner papp-night "$$"
  export CI_TEST_SCENARIO=queued CI_TEST_COMMENT=$comment_outcome
  run_tick
  for tick in 1600 1660 1720 1780; do
    export CI_TEST_NOW=$tick
    run_tick
  done
  [[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*comments')" == 3 ]] || fail 'comment failure retry limit'
  [[ ! -e "$CI_VM_STATE_DIR/heavy-wait-inspr-at-hausnetz-11-1.commented" ]] || fail 'failed comment marked successful'
done
new_case
heavy_owner papp-night "$$"
export CI_TEST_SCENARIO=queued CI_TEST_COMMENT=timeout
run_tick
export CI_TEST_NOW=1600
run_tick
export CI_TEST_NOW=1660 CI_TEST_COMMENT=ok CI_TEST_SCENARIO=empty
run_tick
run_tick
[[ "$(calls 'POST .*cancel')" == 1 && "$(calls 'POST .*comments')" == 2 ]] || fail 'successful comment retry was not remembered'
echo 'ok heavy comment retries: failures logged, three attempts maximum, success remembered independently of cancellation'

wait_reset_contract() {
  local script=${1:-$dispatcher}
  new_case
  heavy_owner papp-night "$$"
  export CI_TEST_SCENARIO=queued
  run_tick "$script" || return 1
  export CI_TEST_NOW=1300
  # Retire the foreign fixture, then acquire through the actual dispatcher.
  heavy_owner hausnetz-ci-vm 99999999
  run_tick "$script" || return 1
  started || return 1
  /bin/bash "$script" stop --force >"$case_dir/out" 2>&1 || return 1
  heavy_owner papp-night "$$"
  export CI_TEST_NOW=1400
  run_tick "$script" || return 1
  export CI_TEST_NOW=1600
  run_tick "$script" || return 1
  [[ "$(calls 'POST .*cancel')" == 0 ]] || return 1
  export CI_TEST_NOW=2000
  run_tick "$script" || return 1
  [[ "$(calls 'POST .*cancel')" == 1 ]] || return 1
}
wait_reset_contract || fail 'acquisition did not reset first-seen wait for a later busy period'
new_case
heavy_owner papp-night "$$"
export CI_TEST_SCENARIO=queued
run_tick
export CI_TEST_NOW=1200 CI_TEST_SCENARIO=empty
run_tick
export CI_TEST_NOW=1500 CI_TEST_SCENARIO=queued
run_tick
export CI_TEST_NOW=1600
run_tick
[[ "$(calls 'POST .*cancel')" == 0 ]] || fail 'run leaving the queue retained its wait'
export CI_TEST_NOW=2100
run_tick
[[ ! -s "$CI_VM_STATE_DIR/heavy-wait-inspr-at-hausnetz-11-1.wait" ]] || fail 'confirmed cancellation retained its wait'
export CI_TEST_NOW=2101 CI_TEST_RUN_ATTEMPT=2
run_tick
export CI_TEST_NOW=2700
run_tick
[[ "$(calls 'POST .*cancel')" == 1 ]] || fail 'rerun did not receive its full wait'
export CI_TEST_NOW=2701
run_tick
[[ "$(calls 'POST .*cancel')" == 2 ]] || fail 'rerun inherited earlier cancellation marker'
# Pruning is based on mtime, with a strict seven-day boundary.
python3 - "$CI_VM_STATE_DIR" <<'PY_PRUNE'
import os, sys
from pathlib import Path
for name, age in [("heavy-wait-old-1-1.wait", 604801), ("heavy-wait-old-1-1.cancel-attempted", 604801), ("heavy-wait-recent-1-1.cancel-tries", 604800)]:
    path = Path(sys.argv[1]) / name
    path.write_text("1\n")
    os.utime(path, (700000-age, 700000-age))
PY_PRUNE
export CI_TEST_NOW=700000 CI_TEST_SCENARIO=empty
run_tick
[[ ! -e "$CI_VM_STATE_DIR/heavy-wait-old-1-1.wait" && ! -e "$CI_VM_STATE_DIR/heavy-wait-old-1-1.cancel-attempted" && -e "$CI_VM_STATE_DIR/heavy-wait-recent-1-1.cancel-tries" ]] || fail 'seven-day run state pruning'
echo 'ok heavy wait reset: acquired lock, queue departure, cancellation and rerun attempts; seven-day wait/outcome pruning'

stale_dispatcher_contract() {
  local helper_copy=${1:-} kind
  for kind in stale live young; do
    new_case
    if [[ -n "$helper_copy" ]]; then cp "$helper_copy" "$CI_VM_HEAVY_LOCK_HELPER"; fi
    export CI_TEST_SCENARIO=queued CI_TEST_NOW=20000
    case "$kind" in
    stale) heavy_owner papp-night 99999999 9199 ;;
    live) heavy_owner papp-night "$$" 9199 ;;
    young) heavy_owner papp-night 99999999 9200 ;;
    esac
    run_tick || return 1
    if [[ "$kind" == stale ]]; then
      started || return 1
      grep -q 'heavy lock stale-broken ' "$case_dir/out" || return 1
    else
      unchanged || return 1
    fi
  done
}
stale_dispatcher_contract || fail 'dispatcher stale break violated dead-and-old requirement'
echo 'ok heavy dispatcher stale break: dead-and-old boots after quarantine; live-and-old and dead-at-three-hours stay busy'

live_hostagent_contract() {
  local helper_copy=${1:-} state
  for state in live unknown; do
    new_case
    if [[ -n "$helper_copy" ]]; then cp "$helper_copy" "$CI_VM_HEAVY_LOCK_HELPER"; fi
    heavy_owner hausnetz-ci-vm 99999999
    export CI_TEST_NOW=12000
    if [[ "$state" == live ]]; then export CI_TEST_HA_LIVE=1; else export CI_TEST_HA_UNKNOWN=1; fi
    run_tick || return 1
    [[ -d "$CI_VM_HEAVY_LOCK" ]] || return 1
    ! grep -q 'residue-released' "$case_dir/out" || return 1
    export CI_TEST_SCENARIO=queued
    # Unknown hostagent inspection must fail acquisition conservatively.
    if run_tick; then [[ "$state" == live ]] || return 1; fi
    unchanged || return 1
    [[ -d "$CI_VM_HEAVY_LOCK" ]] || return 1
  done
}
live_hostagent_contract || fail 'residue or stale recovery released live/unknown hostagent lock'
echo 'ok heavy residue: dead tick PID plus live or uninspectable hostagent never releases, including stale age'

handoff_contract() {
  local script=${1:-$dispatcher}
  new_case
  export CI_TEST_SCENARIO=queued CI_TEST_HANDOFF_FAIL=1
  if run_tick "$script"; then return 1; fi
  [[ "$(calls 'colima start')" == 1 && "$(calls 'colima stop')" == 1 && ! -d "$CI_VM_HEAVY_LOCK" && "$(<"$CI_TEST_VM")" == stopped ]]
}
handoff_contract || fail 'failed hostagent handoff left VM running or lock held'
echo 'ok heavy handoff failure: stops ci, verifies stopped state and releases the tick lock'

new_case
/bin/bash "$dispatcher" start --provision-only >"$case_dir/out" 2>&1
"$CI_TEST_REAL_JQ" -e '.job_url == "https://github.com/inspr-at/hausnetz/actions"' "$CI_VM_HEAVY_LOCK/owner.json" >/dev/null || fail 'operator start lacks configured https URL'
echo 'ok heavy operator start: strict schema includes configured repository actions URL'

# PAPP timestamps and optional URLs survive through the dispatcher, too.
for papp_pid in "$$" 99999999; do
  new_case
  heavy_owner papp-night "$papp_pid" 9199
  python3 - "$CI_VM_HEAVY_LOCK/owner.json" <<'PY_PAPP'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.update(started_at=data["started_at"][:-1] + ".123456+00:00", job_url=None)
path.write_text(json.dumps(data))
PY_PAPP
  export CI_TEST_SCENARIO=queued CI_TEST_NOW=20000
  run_tick
  if [[ "$papp_pid" == 99999999 ]]; then
    started || fail 'PAPP fractional UTC start did not permit stale break'
  else
    unchanged || fail 'PAPP live PID lost during tolerant parsing'
    export CI_TEST_NOW=20600
    run_tick
    grep -q 'COMMENT .*held by papp-night since .* (unknown)' "$case_dir/calls" || fail 'PAPP unknown URL discarded valid owner information'
  fi
done
echo 'ok heavy PAPP dispatcher records: fractional UTC +00:00, null URL, live holder reason and dead stale break'

# An uncertain issue creation is never repeated blindly; a later GET recovers.
new_case
heavy_owner papp-night "$$"
export CI_TEST_SCENARIO=queued CI_TEST_NIGHTLY=1 CI_TEST_ISSUE=timeout
run_tick
export CI_TEST_NOW=1600
run_tick
run_tick
[[ "$(calls 'POST .*/issues$')" == 1 && "$(calls 'POST .*comments')" == 0 ]] || fail 'uncertain issue creation repeated'
echo 429 >"$CI_VM_STATE_DIR/nightly-issue"
export CI_TEST_ISSUE=ok
run_tick
[[ "$(calls 'POST .*/issues$')" == 1 && "$(calls 'POST .*issues/429/comments')" == 1 ]] || fail 'uncertain issue creation not reconciled by title'
echo 'ok heavy issue creation: uncertainty suppresses duplicate creation and recovers through title lookup'

# Definite issue rejection allows recovery; cached issues are freshly validated.
for issue_state in closed locked deleted; do
  new_case
  heavy_owner papp-night "$$"
  export CI_TEST_SCENARIO=queued CI_TEST_NIGHTLY=1 CI_TEST_ISSUE=403
  run_tick
  export CI_TEST_NOW=1600
  run_tick
  [[ ! -e "$CI_VM_STATE_DIR/heavy-issue-inspr-at-hausnetz.create-uncertain" ]] || fail 'definite issue rejection left an uncertain marker'
  export CI_TEST_ISSUE=ok
  run_tick
  [[ "$(calls 'POST .*issues/429/comments')" == 1 ]] || fail 'issue rejection did not recover'
  export CI_TEST_RUN_ID=12
  run_tick
  export CI_TEST_NOW=2200 CI_TEST_ISSUE_STATE="$issue_state"
  run_tick
  [[ "$(calls 'GET .*issues/429$')" == 1 ]] || fail 'cached issue not revalidated'
  [[ "$(calls 'POST .*/issues$')" == 3 ]] || fail 'unusable cached issue was not replaced'
done
echo 'ok heavy issue recovery: definite 403 retried; closed, locked and deleted cached issues revalidated'

python3 - "$dispatcher" "$CI_VM_HEAVY_LOCK_HELPER" "$work" <<'PY_MUTANTS'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
for name, old, new in [
    ("unknown-busy", 'if [ "$unknown" = false ]; then busy_runs; fi', 'busy_runs'),
    ("uncertain-busy", 'retry_count "$key.cancel-tries"\n      [ "$retries" -lt 3 ] || continue', 'retry_count "$key.cancel-tries"'),
    ("false-cancel", '[ "$post_code" = 202 ] && [ "$post_transport" = 0 ]', '[ "$post_code" = 403 ]'),
    ("wait-reset", '  clear_heavy_waits\n}', '  :\n}'),
    ("failed-boot-agent", '    [ "$remaining_hostagent" = 0 ] || return 1', '    :'),
    ("retain-start", '  if [ "$running" = true ]; then heavy_retain || log "ERROR: heavy lock retain failed: $heavy_retain_error"; fi', '  if [ "$running" = true ]; then heavy_retain; fi'),
    ("retain-tick", '\nif [ "$running" = true ]; then heavy_retain || log "ERROR: heavy lock retain failed: $heavy_retain_error"; fi', '\nif [ "$running" = true ]; then heavy_retain; fi'),
    ("handoff-ignore", 'hostagent=$(bounded 20 hostagent) || return 1', 'hostagent=$(bounded 20 hostagent) || return 0')]:
    assert source.count(old) == 1, (name, source.count(old))
    Path(sys.argv[3], name + '-mutant.sh').write_text(source.replace(old, new))
helper = Path(sys.argv[2]).read_text()
for name, old, new in [
    ("stale-dispatch", 'dead(owner) and now - started > 10800', 'dead(owner) or now - started > 10800'),
    ("residue-agent", ' and hostagent == 0', '')]:
    assert old in helper
    Path(sys.argv[3], name + '-mutant.py').write_text(helper.replace(old, new))
PY_MUTANTS
if failed_boot_hostagent_contract "$work/failed-boot-agent-mutant.sh"; then fail 'failed boot live hostagent mutant survived'; fi
if retain_failure_contract "$work/retain-tick-mutant.sh"; then fail 'fatal retain tick mutant survived'; fi
if retain_failure_contract "$work/retain-start-mutant.sh" start; then fail 'fatal retain start mutant survived'; fi
echo 'ok heavy retain must-fail mutants: fatal calls in tick and start rejected'
if unknown_busy_contract "$work/unknown-busy-mutant.sh"; then fail 'unknown busy scan mutant survived'; fi
if uncertain_cancel_contract "$work/uncertain-busy-mutant.sh"; then fail 'unbounded uncertain cancel mutant survived'; fi
if forbidden_cancel_contract "$work/false-cancel-mutant.sh"; then fail 'false cancellation on 403 mutant survived'; fi
if wait_reset_contract "$work/wait-reset-mutant.sh"; then fail 'wait reset mutant survived'; fi
if stale_dispatcher_contract "$work/stale-dispatch-mutant.py"; then fail 'dispatcher stale OR mutant survived'; fi
if live_hostagent_contract "$work/residue-agent-mutant.py"; then fail 'live hostagent residue mutant survived'; fi
if handoff_contract "$work/handoff-ignore-mutant.sh"; then fail 'ignored handoff failure mutant survived'; fi
echo 'ok heavy fix-round must-fail mutants: unknown scan, unbounded cancel retries, false 403 cancellation, wait reset, stale OR, live hostagent residue and ignored handoff failure rejected'

python3 - "$dispatcher" "$work" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
for name, old, new in [
    ('heavy-boot', 'if heavy_acquire; then :; else', 'if true; then heavy_acquired=true; else'),
    ('heavy-repeat', '[ ! -e "$state/$key.cancel-attempted" ]', '[ -n "$key" ]')]:
    assert old in source
    Path(sys.argv[2], name + '-mutant.sh').write_text(source.replace(old, new))
PY
if acquire_contract "$work/heavy-boot-mutant.sh"; then fail 'boot without lock mutant survived'; fi
if busy_pr_contract "$work/heavy-repeat-mutant.sh"; then fail 'repeated cancellation mutant survived'; fi
echo 'ok heavy must-fail mutants: boot without lock and repeated cancel rejected (host tests reject stale OR and foreign release)'

python3 - "$dispatcher" "$work" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
for name, old, new in [('labels', 'all(.labels[]; ascii_downcase', 'any(.labels[]; ascii_downcase'),
                       ('grace', '-ge 1200', '-ge 1199'),
                       ('unknown-cap', 'read_stamp unknown-since', 'stamp unknown-since\n    read_stamp unknown-since'),
                       ('queue-cap', '-ge 600', '-ge 601'),
                       ('active-ssh', 'if [ "$running" = true ] && [ "$qos_failed" = false ]; then', 'if false; then'),
                       ('worker-cap', '-ge 3600 ]\n}', '-ge 3601 ]\n}'),
                       ('guest-exit-code', 'status=$(guest_status 150 drain)', 'if guest 150 drain; then status=drained; else rc=$?; if [ "$rc" -eq 3 ]; then status=worker-busy; else status=unknown; fi; fi'),
                       ('token-retirement', 'trash "$token" || return 1', ': "$token" || return 1'),
                       ('colima-home', '# Keep the CLI', 'export COLIMA_HOME="$HOME/.colima"\n# Keep the CLI')]:
    assert old in source
    Path(sys.argv[2], name + '-mutant.sh').write_text(source.replace(old, new))
PY
new_case
export CI_TEST_SCENARIO=wrong-arch
run_tick "$work/labels-mutant.sh"
if unchanged; then fail 'label mutant survived wrong-architecture assertion'; fi
new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/last-demand"
export CI_TEST_NOW=2199
run_tick "$work/grace-mutant.sh"
if unchanged; then fail 'grace mutant survived boundary assertion'; fi
new_case
export CI_TEST_SCENARIO=queued
if run_tick "$work/colima-home-mutant.sh"; then fail 'legacy Colima home mutant survived'; fi
grep -q 'requires the module XDG Colima and Lima homes' "$case_dir/out" || fail 'legacy home mutant failed for the wrong reason'
[[ ! -s "$case_dir/calls" && ! -e "$HOME/.colima" ]] || fail 'legacy home mutant caused side effects'
echo 'ok mutants: weakened labels, early shutdown and legacy Colima home fail their contracts'
new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/unknown-since"
export CI_TEST_SCENARIO=failure CI_TEST_WORKER=0 CI_TEST_NOW=4600
run_tick "$work/unknown-cap-mutant.sh"
if [[ "$(calls 'colima stop')" != 0 ]]; then fail 'unknown-cap mutant did not exercise the uptime bound'; fi
new_case
echo running >"$case_dir/vm"
echo 1000 >"$case_dir/state/queue-since"
export CI_TEST_SCENARIO=queued CI_TEST_NOW=1600
run_tick "$work/queue-cap-mutant.sh"
if [[ "$(calls 'colima stop')" != 0 ]]; then fail 'queue-cap mutant did not exercise the pickup bound'; fi
echo 'ok uptime mutants: resetting the unknown timer and delaying the pickup cap violate the stop contracts'

if active_ssh_contract "$work/active-ssh-mutant.sh"; then fail 'active SSH mutant survived the active-job retention contract'; fi
if worker_cap_contract "$work/worker-cap-mutant.sh" empty; then fail 'local-only worker cap mutant survived the absolute-cap contract'; fi
if status_protocol_contract "$work/guest-exit-code-mutant.sh"; then fail 'guest exit-code parsing mutant survived the status protocol contract'; fi
echo 'ok regression mutants: direct stop on a single active-job SSH failure and an extended local-worker cap violate their contracts'
echo 'ok Colima mutant: parsing guest exit codes instead of stdout loses drain retention and violates the shared protocol contract'

new_case
mkdir -p "$CI_VM_STATE_DIR/secrets"
printf 'fixture-registration-value\n' >"$CI_VM_STATE_DIR/secrets/hausnetz.token"
export CI_TEST_ENROLLED=hausnetz CI_TEST_SCENARIO=queued
run_tick "$work/token-retirement-mutant.sh"
[[ -f "$CI_VM_STATE_DIR/secrets/hausnetz.token" ]] || fail 'token-retirement mutant did not violate lifecycle contract'
echo 'ok token mutant: omitted host retirement violates the enrolled-token contract'

python3 - "$CI_VM_HOST_HELPER" <<'PY'
import subprocess, sys, time
start = time.monotonic()
child = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(30)'
parent = f'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{child!r}]); time.sleep(30)'
exercise = f'import runpy,sys; helper=runpy.run_path({sys.argv[1]!r}); sys.exit(helper["bounded"](.5, [sys.executable,"-c",{parent!r}]))'
result = subprocess.run([sys.executable, '-c', exercise], capture_output=True, timeout=7)
assert result.returncode == 124 and time.monotonic() - start < 7, 'CLI timeout did not terminate its process group'
PY
echo 'ok timeout: host CLI process groups have a real deadline'
echo 'ci-vm dispatcher test: PASS'
