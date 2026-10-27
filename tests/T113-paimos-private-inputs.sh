#!/usr/bin/env bash
# OPS-480: offline CI structure and real composite-script failure fixtures.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf '%s: run this contract under Bash 5 (found %s)\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
CONTRACT_BASH="$BASH" python3 -B - <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def yaml(path):
    # Match test_pharos_ci.py: runner Ruby/Psych, no downloaded Python packages.
    return json.loads(subprocess.check_output([
        'ruby', '-rjson', '-rpsych', '-e',
        'puts JSON.generate(Psych.load_file(ARGV[0]))', str(path),
    ], text=True))


action_path = Path('.github/actions/paimos-private-inputs/action.yml')
assert action_path.is_file()
action_text = action_path.read_text()
action = yaml(action_path)
assert action['runs']['using'] == 'composite'
step, = action['runs']['steps']
assert step['shell'] == 'bash'
assert step['env'] == {
    'PAIMOS_DEPLOY_KEY': '${{ inputs.paimos-key }}',
    'PAIMOS_LEGACY_DEPLOY_KEY': '${{ inputs.paimos-legacy-key }}',
}
assert set(action['inputs']) == {'paimos-key', 'paimos-legacy-key'}
script = step['run']
assert 'flake.lock' in script and '.nodes[$node].locked' in script
assert '.owner' in script and '.repo' in script and '.rev' in script and '.narHash' in script
assert '[ "$hash" != "$nar_hash" ]' in script
assert 'GIT_SSH_COMMAND="$ssh_command" nix flake prefetch --json' in script
assert 'GITHUB_ENV' not in script and 'GITHUB_OUTPUT' not in script
assert '$RUNNER_TEMP/paimos-inputs-ssh.' in script
assert 'ssh-keyscan ' not in script and not re.search(r'\b[0-9a-f]{40}\b', script)
host_key, = re.findall(r'github.com ssh-ed25519 [A-Za-z0-9+/=]+', action_text)
assert host_key in Path('.github/actions/hausnetz-input/action.yml').read_text()

workflow = yaml('.github/workflows/check.yml')
jobs = workflow['jobs']
expected_jobs = {'check', *(f'pharos-contracts-{n}' for n in range(1, 5))}
found_jobs = set()
for name, job in jobs.items():
    steps = job['steps']
    setups = [i for i, s in enumerate(steps)
              if s.get('uses') == './.github/actions/pharos-nix'
              or s.get('uses', '').startswith('cachix/install-nix-action@')]
    consumers = []
    for i, s in enumerate(steps):
        text = s.get('run', '')
        # Include indirect shell/Python/macOS consumers, not only workflow nix eval.
        for test in re.findall(r'tests/[\w./-]+\.(?:sh|py)', text):
            if test == 'tests/T113-paimos-private-inputs.sh':
                continue  # This contract executes mocked Nix only.
            path = Path(test)
            if path.is_file():
                text += '\n' + path.read_text()
        if re.search(r'\bnix\s+(?:eval|build|flake)\b|builtins\.getFlake', text):
            consumers.append(i)
    prefetch = [(i, s) for i, s in enumerate(steps)
                if s.get('uses') == './.github/actions/paimos-private-inputs']
    if not setups and not consumers:
        assert not prefetch, name
        continue
    found_jobs.add(name)
    assert len(prefetch) == 1, (name, 'missing or duplicate prefetch')
    (index, configured), = prefetch
    setup, = setups
    assert index == setup + 1, (name, 'prefetch must immediately follow Nix/public cache setup')
    assert all(index < i for i in consumers), (name, 'flake consumer before prefetch')
    # Also precede every explicit Nix command in this job.
    assert all(index < i for i, s in enumerate(steps)
               if re.search(r'\bnix(?:-shell|-instantiate)?\s', s.get('run', ''))), name
    assert configured['with'] == {
        'paimos-key': '${{ secrets.PAIMOS_DEPLOY_KEY }}',
        'paimos-legacy-key': '${{ secrets.PAIMOS_LEGACY_DEPLOY_KEY }}',
    }, name
    assert 'continue-on-error' not in configured
    if name.startswith('pharos-contracts-'):
        assert configured['if'] == "steps.pin.outputs.pin_only != 'true'", name
    else:
        assert 'if' not in configured, name  # Every matrix host needs the inputs.
assert found_jobs == expected_jobs, found_jobs
assert sum('bash tests/T113-paimos-private-inputs.sh' in s.get('run', '')
           for job in jobs.values() for s in job['steps']) == 1
# The public cache must finish synchronously before any private input is fetched.
public_setup = yaml('.github/actions/pharos-nix/action.yml')
assert public_setup['runs']['steps'][-1]['uses'].startswith('nix-community/cache-nix-action/save@')
assert all('paimos-private-inputs' not in json.dumps(s) for s in public_setup['runs']['steps'])
print('OPS-480 workflow coverage, ordering, secrets and public-cache boundary: OK')

lock = json.loads(Path('flake.lock').read_text())
# Different revisions prove that the executed action uses the lock, not pins.
for node, revision in (('aeon', '1' * 40), ('paimos', '2' * 40)):
    lock['nodes'][node]['locked']['rev'] = revision
fixture_keys = {'aeon': 'OPS-480 synthetic current key', 'paimos': 'OPS-480 synthetic legacy key'}

mock = r'''
import json, os, pathlib, shlex, stat, sys
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
lock = json.loads(pathlib.Path('flake.lock').read_text())
if command == 'curl':
    assert '--head' in args and '--fail' in args and '--location' in args
    assert '--max-time' in args and '--output' in args
    node = 'paimos' if '/paimos-legacy/' in args[-1] else 'aeon'
    locked = lock['nodes'][node]['locked']
    assert args[-1] == f"https://github.com/{locked['owner']}/{locked['repo']}/archive/{locked['rev']}.tar.gz"
    record = {'command': command, 'node': node}
else:
    assert args[:3] == ['flake', 'prefetch', '--json'] and len(args) == 4
    node = 'paimos' if '/paimos-legacy?' in args[-1] else 'aeon'
    locked = lock['nodes'][node]['locked']
    assert args[-1] == f"git+ssh://git@github.com/{locked['owner']}/{locked['repo']}?rev={locked['rev']}"
    ssh = shlex.split(os.environ['GIT_SSH_COMMAND'])
    assert ssh[:3] == ['ssh', '-F', '/dev/null']
    assert all(x in ssh for x in ['IdentitiesOnly=yes', 'BatchMode=yes',
                                  'StrictHostKeyChecking=yes', 'GlobalKnownHostsFile=/dev/null'])
    key = pathlib.Path(ssh[ssh.index('-i') + 1])
    assert key.name == node
    assert key.read_text() == json.loads(os.environ['FIXTURE_KEYS'])[node] + '\n'
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert stat.S_IMODE(key.parent.stat().st_mode) == 0o700
    known_hosts = next(x.split('=', 1)[1] for x in ssh if x.startswith('UserKnownHostsFile='))
    assert pathlib.Path(known_hosts).read_text() == os.environ['FIXTURE_HOST_KEY'] + '\n'
    assert 'PAIMOS_DEPLOY_KEY' not in os.environ and 'PAIMOS_LEGACY_DEPLOY_KEY' not in os.environ
    record = {'command': command, 'node': node}
with open(os.environ['FIXTURE_LOG'], 'a') as output:
    output.write(json.dumps(record) + '\n')
if command == 'curl':
    sys.exit(0 if node in json.loads(os.environ['FIXTURE_PUBLIC']) else 22)
if os.environ.get('FIXTURE_FAIL') == node:
    print('synthetic fetch failure', file=sys.stderr)
    sys.exit(1)
if os.environ.get('FIXTURE_BAD_JSON') == node:
    print('malformed fixture')
    sys.exit(0)
print(json.dumps({'hash': 'sha256-wrong' if os.environ.get('FIXTURE_MISMATCH') == node else locked['narHash']}))
'''


def exercise(label, keys=('aeon', 'paimos'), public=(), changed=None, failure=None,
             mismatch=None, bad_json=None, error=None, expected_calls=None):
    with tempfile.TemporaryDirectory(prefix='ops480-contract-') as tmp:
        root = Path(tmp)
        (root / 'bin').mkdir()
        for command in ('nix', 'curl'):
            path = root / 'bin' / command
            path.write_text(f'#!{sys.executable}\n' + mock)
            path.chmod(0o700)
        (root / 'flake.lock').write_text(json.dumps(lock if changed is None else changed))
        github_env = root / 'github-env'
        github_env.write_text('unchanged\n')
        github_output = root / 'github-output'
        github_output.write_text('unchanged\n')
        child_env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                         RUNNER_TEMP=str(root), GITHUB_ENV=str(github_env),
                         GITHUB_OUTPUT=str(github_output),
                         GIT_SSH_COMMAND='existing hausnetz override',
                         PAIMOS_DEPLOY_KEY=fixture_keys['aeon'] if 'aeon' in keys else '',
                         PAIMOS_LEGACY_DEPLOY_KEY=fixture_keys['paimos'] if 'paimos' in keys else '',
                         FIXTURE_LOG=str(root / 'calls'), FIXTURE_KEYS=json.dumps(fixture_keys),
                         FIXTURE_HOST_KEY=host_key, FIXTURE_PUBLIC=json.dumps(public),
                         FIXTURE_FAIL=failure or '', FIXTURE_MISMATCH=mismatch or '',
                         FIXTURE_BAD_JSON=bad_json or '')
        result = subprocess.run([os.environ['CONTRACT_BASH'], '-c', script], cwd=root,
                                env=child_env, text=True, capture_output=True, timeout=15)
        output = result.stdout + result.stderr
        assert all(key not in output for key in fixture_keys.values()), label
        assert github_env.read_text() == github_output.read_text() == 'unchanged\n', label
        if error:
            assert result.returncode != 0 and '::error::' in output and error in output, (label, output)
        else:
            assert result.returncode == 0, (label, output)
            assert output.count('::notice::') == 2 - len(keys), (label, output)
        log = root / 'calls'
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        assert [(c['command'], c['node']) for c in calls] == expected_calls, (label, calls)
        # Runner-temp is the sole persistence boundary; keys never enter the store.
        ssh_dir, = root.glob('paimos-inputs-ssh.*')
        assert all(p.name in {*keys, 'known_hosts'} for p in ssh_dir.iterdir())
        print(f'OPS-480 {label}: OK')


exercise('two isolated keys and lock-driven revisions', expected_calls=[('nix', 'aeon'), ('nix', 'paimos')])
exercise('no secrets while public', keys=(), public=('aeon', 'paimos'),
         expected_calls=[('curl', 'aeon'), ('curl', 'paimos')])
exercise('missing current key after privacy flip', keys=(), error='PAIMOS_DEPLOY_KEY is required',
         expected_calls=[('curl', 'aeon')])
exercise('missing legacy key after privacy flip', keys=('aeon',),
         error='PAIMOS_LEGACY_DEPLOY_KEY is required', expected_calls=[('nix', 'aeon'), ('curl', 'paimos')])
exercise('legacy-only key while current input public', keys=('paimos',), public=('aeon',),
         expected_calls=[('curl', 'aeon'), ('nix', 'paimos')])
exercise('current-only key while legacy input public', keys=('aeon',), public=('paimos',),
         expected_calls=[('nix', 'aeon'), ('curl', 'paimos')])
for node in ('aeon', 'paimos'):
    calls = [('nix', 'aeon')] + ([('nix', 'paimos')] if node == 'paimos' else [])
    exercise(f'{node} hash mismatch fails closed', mismatch=node, error='hash does not match', expected_calls=calls)
    exercise(f'{node} malformed prefetch JSON fails closed', bad_json=node, error='hash does not match', expected_calls=calls)
    exercise(f'{node} SSH failure names its secret', failure=node, error='SSH prefetch failed', expected_calls=calls)
for field, value in (('rev', 'main'), ('owner', 'unexpected-owner'), ('repo', 'unexpected-repo'),
                     ('narHash', None), ('rev', 'a' * 40 + '\ninjected'), ('type', 'git')):
    changed = copy.deepcopy(lock)
    changed['nodes']['aeon']['locked'][field] = value
    exercise(f'invalid locked {field} rejected before fetch', changed=changed,
             error='Invalid locked Paimos input', expected_calls=[])
print('OPS-480 private Paimos input contracts: PASS (offline; no real keys or Nix fetches)')
PY
