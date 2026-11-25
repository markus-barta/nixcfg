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
mkdir -p "$work/bin"

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
from urllib.parse import parse_qs, urlparse
args = sys.argv[1:]
assert args[0] == "-q", "curl must ignore implicit user config"
assert "--config" in args and args[args.index("--config") + 1] == "-"
assert not any("fixture-agent-value" in a for a in args), "token in argv"
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
labels = ["self-hosted", "Linux", "ARM64", "mbp2607", repo, "kvm"]
if not is_jobs:
    if scenario == "malformed": print('{}'); sys.exit()
    if scenario == "truncated": print('{"workflow_runs": [], "total_count": 101}'); sys.exit()
    if scenario == "short-runs": print('{"workflow_runs": [], "total_count": 1}'); sys.exit()
    if scenario == "negative-count": print('{"workflow_runs": [], "total_count": -1}'); sys.exit()
    status = query["status"][0]
    active = status == ("in_progress" if scenario == "progress" else "queued")
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
    status = "in_progress" if scenario == "progress" else "completed" if scenario == "completed" else "queued"
    jobs = [{"status": status, "labels": labels, "runner_name": "mbp2607-hausnetz"}]
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
printf 'colima %s\n' "$*" >>"$CI_TEST_CALLS"
if [[ "$1" == --profile ]]; then
  [[ "$*" == '--profile ci ssh -- sudo /usr/local/libexec/ci-vm/host-ready' ]] || exit 86
  if [[ "${CI_TEST_REQUIRE_CLOSED_STDIN:-0}" == 1 ]] && IFS= read -r ignored; then exit 87; fi
  exit "${CI_TEST_READY_FAIL:-0}"
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
    [[ ! -L "$HOME/.colima/ci/colima.yaml" ]] || exit 82
    cmp -s "$CI_VM_CONFIG" "$HOME/.colima/ci/colima.yaml" || exit 83
    printf '\n# rewritten by Colima\n' >>"$HOME/.colima/ci/colima.yaml"
    echo running >"$CI_TEST_VM"
    ;;
  stop) echo stopped >"$CI_TEST_VM" ;;
  *) exit 84 ;;
esac
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

new_case() {
  case_dir=$(mktemp -d "$work/case.XXXXXXXX")
  mkdir -p "$case_dir/home" "$case_dir/state"
  echo stopped >"$case_dir/vm"
  : >"$case_dir/calls"
  printf 'GH_TOKEN=fixture-agent-value\n' >"$case_dir/agent.env"
  chmod 0600 "$case_dir/agent.env"
  cp "$work/repos.json" "$case_dir/repos.json"
  export HOME="$case_dir/home" PATH="$work/bin:$PATH"
  export CI_VM_STATE_DIR="$case_dir/state" CI_VM_CONFIG="$work/declared.yaml"
  export CI_VM_REPOSITORIES="$case_dir/repos.json" CI_VM_AGENT_TOKEN_FILE="$case_dir/agent.env"
  export CI_VM_HOST_HELPER="$root/hosts/mbp2607/files/ci-vm/host.py" CI_VM_QOS="$work/bin/qos"
  export CI_TEST_SCENARIO=empty CI_TEST_NOW=1000 CI_TEST_CALLS="$case_dir/calls" CI_TEST_VM="$case_dir/vm" CI_TEST_QOS_FAIL=0 CI_TEST_READY_FAIL=0 CI_TEST_REQUIRE_CLOSED_STDIN=0
}
run_tick() { /bin/bash "${1:-$dispatcher}" tick >"$case_dir/out" 2>&1; }
calls() { grep -c "$1" "$case_dir/calls" || true; }
unchanged() { [[ "$(calls 'colima start')" == 0 && "$(calls 'colima stop')" == 0 ]]; }
started() { [[ "$(calls 'colima start')" == 1 && "$(<"$case_dir/vm")" == running ]]; }

for scenario in wrong-arch wrong-host no-labels completed empty; do
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
echo running >"$case_dir/vm"
echo 1 >"$case_dir/state/last-demand"
export CI_TEST_SCENARIO=progress CI_TEST_NOW=5000
run_tick
unchanged && [[ "$(<"$case_dir/state/last-demand")" == 5000 ]] || fail 'in-progress job failed to retain ci'
echo 'ok active: in-progress jobs reset grace without restarting ci'

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

for scenario in failure malformed malformed-jobs truncated short-runs short-jobs negative-count; do
  new_case
  echo running >"$case_dir/vm"
  echo 1 >"$case_dir/state/last-demand"
  export CI_TEST_SCENARIO=$scenario CI_TEST_NOW=5000
  run_tick
  unchanged && [[ "$(<"$case_dir/state/last-demand")" == 5000 ]] || fail "$scenario treated as idle"
done
new_case
echo running >"$case_dir/vm"
export CI_VM_AGENT_TOKEN_FILE="$case_dir/absent.env"
run_tick
unchanged || fail 'missing agent token changed ci'
echo 'ok uncertainty: API/auth/schema/pagination errors preserve VM and reset grace'

for value in missing corrupt 9999999; do
  new_case
  echo running >"$case_dir/vm"
  if [[ "$value" != missing ]]; then echo "$value" >"$case_dir/state/last-demand"; fi
  run_tick
  unchanged && [[ "$(<"$case_dir/state/last-demand")" == 1000 ]] || fail "$value clock/state recovery"
done
echo 'ok recovery: absent/corrupt/future timestamps begin a fresh grace period'

new_case
export CI_TEST_SCENARIO=queued CI_TEST_QOS_FAIL=1
if run_tick; then fail 'unverified QoS passed'; fi
[[ "$(calls 'colima start')" == 1 && "$(calls 'colima stop')" == 1 ]] || fail 'QoS failure left ci running'
new_case
export CI_TEST_SCENARIO=queued CI_TEST_READY_FAIL=1
if run_tick; then fail 'failed provisioning passed'; fi
[[ "$(calls 'colima start')" == 1 && "$(calls 'colima stop')" == 1 ]] || fail 'provision failure left ci running'
new_case
mkdir -p "$HOME/.colima/ci"
echo unrelated >"$HOME/.colima/ci/colima.yaml"
export CI_TEST_SCENARIO=queued
if run_tick; then fail 'unowned ci profile was adopted'; fi
unchanged && [[ "$(<"$HOME/.colima/ci/colima.yaml")" == unrelated ]] || fail 'unowned profile modified'
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
child = int(subprocess.check_output([sys.executable, helper, 'lock', os.environ['CI_VM_STATE_DIR'] + '/dispatcher.lock', sys.executable, '-c', code], text=True))
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
                       ('grace', '-ge 1200', '-ge 1199')]:
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
echo 'ok mutants: weakened label matching and early shutdown both fail their contracts'
echo 'ci-vm dispatcher test: PASS'
