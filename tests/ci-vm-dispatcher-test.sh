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
    f.write("GET " + url + "\n")
assert url.startswith("https://api.github.com/repos/inspr-at/"), url
assert "registration-token" not in url
scenario = os.environ["CI_TEST_SCENARIO"]
if scenario == "failure": sys.exit(22)
if scenario == "mixed" and "/hausnetz/" in url: sys.exit(22)
parsed = urlparse(url)
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
        runs = [{"id": 11}] if active else []
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
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/control worker-active') exit "${CI_TEST_WORKER:-1}" ;;
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/control enrolled')
      if [[ "${CI_TEST_ENROLLED_FAIL:-0}" == 1 ]]; then exit 255; fi
      if [[ -e "$CI_VM_STATE_DIR/enrolled" ]]; then printf 'hausnetz\n'; else printf '%s' "${CI_TEST_ENROLLED:-}"; fi
      ;;
    '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/control drain')
      if [[ "${CI_TEST_WORKER:-1}" == 0 ]]; then exit 3; fi
      exit "${CI_TEST_DRAIN:-0}"
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
    [[ ! -L "$COLIMA_HOME/ci/colima.yaml" ]] || exit 82
    if [[ "${CI_TEST_START_FAIL:-0}" == 1 ]]; then exit 1; fi
    cmp -s "$CI_VM_CONFIG" "$COLIMA_HOME/ci/colima.yaml" || exit 83
    printf '\n# rewritten by Colima\n' >>"$COLIMA_HOME/ci/colima.yaml"
    echo running >"$CI_TEST_VM"
    ;;
  stop) echo stopped >"$CI_TEST_VM" ;;
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
set -euo pipefail
[[ "$1 $2 $3" == '-b -c background' ]] || exit 85
shift 3
printf 'taskpolicy background\n' >>"$CI_TEST_CALLS"
exec "$@"
STUB
cat >"$work/bin/qos" <<'STUB'
#!/usr/bin/env bash
printf 'qos ci\n' >>"$CI_TEST_CALLS"
exit "${CI_TEST_QOS_FAIL:-0}"
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
  export CI_TEST_SCENARIO=empty CI_TEST_NOW=1000 CI_TEST_CALLS="$case_dir/calls" CI_TEST_VM="$case_dir/vm" CI_TEST_QOS_FAIL=0 CI_TEST_READY_FAIL=0 CI_TEST_REQUIRE_CLOSED_STDIN=0
  export CI_TEST_WORKER=1 CI_TEST_DRAIN=0 CI_TEST_START_FAIL=0 CI_TEST_ENROLLED='' CI_TEST_JQ_FAIL=''
  export CI_TEST_SSH_FAIL_ONCE=0 CI_TEST_ENROLL_ON_READY=0 CI_TEST_ENROLLED_FAIL=0
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
[[ "$(calls 'taskpolicy background')" == 1 && "$(calls 'qos ci')" == 1 ]] || fail 'background enforcement'
[[ "$(<"$case_dir/state/last-demand")" == 1000 ]] || fail 'demand timestamp'
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$case_dir/state/secrets")" == 0o700 ]] || fail 'secret directory mode'
# Start again after Colima rewrote the file: starter must replace it with a copy.
echo stopped >"$case_dir/vm"
run_tick
[[ "$(calls 'colima start')" == 2 ]] || fail 'copied config did not survive a Colima rewrite'
echo 'ok demand: queued jobs start ci under background QoS; writable config is refreshed for each start'

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
echo 'ok regression mutants: direct stop on a single active-job SSH failure and an extended local-worker cap violate their contracts'

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
