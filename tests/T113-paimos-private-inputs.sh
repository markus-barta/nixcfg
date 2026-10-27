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
import shutil
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
    'REQUIRE_KEYS': '${{ inputs.require-keys }}',
}
assert set(action['inputs']) == {'paimos-key', 'paimos-legacy-key', 'require-keys'}
script = step['run']
assert 'flake.lock' in script and '.nodes[.root].inputs[$node]' in script
assert '.owner' in script and '.repo' in script and '.rev' in script and '.narHash' in script
assert '[ "$hash" != "$nar_hash" ]' in script
assert 'GIT_SSH_COMMAND="$ssh_command" nix flake prefetch --json' in script
assert 'GITHUB_ENV' not in script and 'GITHUB_OUTPUT' not in script
assert '$RUNNER_TEMP/paimos-inputs-ssh.' in script
assert 'ssh-keyscan ' not in script and not re.search(r'\b[0-9a-f]{40}\b', script)
host_key, = re.findall(r'github.com ssh-ed25519 [A-Za-z0-9+/=]+', action_text)
assert host_key in Path('.github/actions/hausnetz-input/action.yml').read_text()
assert host_key in Path('scripts/aeon-pin-gate.py').read_text()

# Scan every workflow and recursively inspect referenced local scripts/actions.
# These jobs run standalone expressions/tools, never the repository flake.
standalone = {
    ('build.yml', 'build'): 'nix-build of pkgs/nixbit/package.nix via <nixpkgs>',
    ('format-check.yml', 'format-check'): 'formatter packages from devenv.lock, eval --file only',
    ('janus-engine-pin-check.yml', 'pin-check'): 'offline eval --expr of local value-free metadata',
}
# These execute mock subprocesses and inspect workflow YAML; expanding their
# source would mistake fixture strings for actual flake consumers.
offline = {'tests/T113-paimos-private-inputs.sh', 'tests/test_aeon_pin_gate.py',
           'tests/test_pharos_ci.py'}


def expand(text, seen=None):
    seen = set() if seen is None else seen
    for name in re.findall(r'(?:tests|scripts)/[\w./-]+\.(?:sh|py|nix)', text):
        if name in seen or name in offline:
            continue
        seen.add(name)
        path = Path(name)
        if path.is_file():
            text += '\n' + expand(path.read_text().replace('$SCRIPT_DIR/', str(path.parent) + '/'), seen)
    for name in re.findall(r'\./\.github/actions/[\w/-]+', text):
        if name.endswith('/paimos-private-inputs') or name in seen:
            continue
        seen.add(name)
        path = Path(name) / 'action.yml'
        if path.is_file():
            for nested in yaml(path)['runs']['steps']:
                text += '\n' + expand(nested.get('run', '') + '\n' + nested.get('uses', ''), seen)
    return '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))


expected_jobs = {
    ('check.yml', 'check'),
    *(('check.yml', f'pharos-contracts-{n}') for n in range(1, 5)),
    ('pharos-system-update.yml', 'propose'),
    ('pharos-host-removal.yml', 'propose'),
    ('pharos-host-settings.yml', 'update-and-merge'),
    ('pharos-release-rollout.yml', 'propose'),
    ('update-flake-lock.yml', 'update-and-merge'),
}
found_jobs = set()
seen_standalone = set()
trusted_keys = "${{ github.actor != 'dependabot[bot]' && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) }}"
for path in sorted(Path('.github/workflows').glob('*')):
    if path.suffix not in ('.yml', '.yaml'):
        continue
    for name, job in yaml(path)['jobs'].items():
        identity = (path.name, name)
        steps = job.get('steps', [])
        texts = [expand(s.get('run', '') + '\n' + s.get('uses', '')) for s in steps]
        consumers = [i for i, text in enumerate(texts)
                     if re.search(r'\bnix(?:-shell|-build|-instantiate)?(?:\s|[\"\'],\s*[\"\'](?:eval|build|flake))|builtins\.getFlake|\b(?:nixos-rebuild|darwin-rebuild|home-manager|devenv)\s|DeterminateSystems/update-flake-lock@', text)]
        prefetch = [(i, s) for i, s in enumerate(steps)
                    if s.get('uses') == './.github/actions/paimos-private-inputs']
        if identity in standalone:
            combined = '\n'.join(texts)
            assert not re.search(r'builtins\.getFlake|\.#|\bnix\s+flake\s|\b(?:nixos-rebuild|darwin-rebuild|home-manager|devenv)\s', combined), identity
            assert not prefetch and consumers, identity
            seen_standalone.add(identity)
            continue
        if not consumers and not prefetch:
            continue
        found_jobs.add(identity)
        assert len(prefetch) == 1, (identity, 'missing or duplicate prefetch')
        (index, configured), = prefetch
        setups = [i for i, s in enumerate(steps)
                  if s.get('uses') == './.github/actions/pharos-nix'
                  or s.get('uses', '').startswith(('cachix/install-nix-action@', 'DeterminateSystems/nix-installer-action@'))]
        setup, = setups
        assert index == setup + 1, (identity, 'prefetch must follow Nix/public cache setup')
        # The setup's own public-tool fetches are exempt; every later Nix/script
        # consumer (including lock-update actions) must follow private prefetch.
        assert all(index < i for i in consumers if i != setup), (identity, consumers)
        assert configured['with'] == {
            'paimos-key': '${{ secrets.PAIMOS_DEPLOY_KEY }}',
            'paimos-legacy-key': '${{ secrets.PAIMOS_LEGACY_DEPLOY_KEY }}',
            'require-keys': trusted_keys if path.name == 'check.yml' else 'true',
        }, identity
        assert 'continue-on-error' not in configured
        if name.startswith('pharos-contracts-'):
            assert configured['if'] == "steps.pin.outputs.pin_only != 'true'", identity
        else:
            assert 'if' not in configured, identity
assert found_jobs == expected_jobs, found_jobs
assert seen_standalone == set(standalone), seen_standalone
workflow = yaml('.github/workflows/check.yml')
jobs = workflow['jobs']
assert sum('bash tests/T113-paimos-private-inputs.sh' in s.get('run', '')
           for job in jobs.values() for s in job.get('steps', [])) == 1
verify = next(s for s in jobs['aeon-pin-gate']['steps'] if 'scripts/aeon-pin-gate.py verify' in s.get('run', ''))
assert verify['env']['PAIMOS_DEPLOY_KEY'] == '${{ secrets.PAIMOS_DEPLOY_KEY }}'
assert 'GH_TOKEN' not in verify['env']
assert jobs['check']['steps'][1]['uses'] == yaml('.github/actions/pharos-nix/action.yml')['runs']['steps'][0]['uses']
# Both updaters must preserve reviewed private/release pins.
for source in (yaml('.github/workflows/update-flake-lock.yml')['jobs']['update-and-merge']['steps'],
               [{'run': Path('scripts/prepare-pharos-system-update.sh').read_text()}]):
    selection, = re.findall(r"jq -r '(\.nodes\[\.root\]\.inputs[^']+)' flake.lock", '\n'.join(s.get('run', '') for s in source))
    selected = subprocess.check_output(['jq', '-r', selection, 'flake.lock'], text=True).split()
    assert selected and not {'hausnetz', 'aeon', 'paimos'}.intersection(selected)
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
    locked = lock['nodes'][lock['nodes'][lock['root']]['inputs'][node]]['locked']
    assert args[-1] == f"https://github.com/{locked['owner']}/{locked['repo']}/archive/{locked['rev']}.tar.gz"
    record = {'command': command, 'node': node}
elif args[0] == 'eval':
    assert '--offline' in args and '--raw' in args
    assert not list(pathlib.Path(os.environ['RUNNER_TEMP']).glob('paimos-inputs-ssh.*'))
    assert os.environ['GIT_SSH_COMMAND'] == 'false'
    assert os.environ['GIT_CONFIG_VALUE_0'] == 'never'
    assert os.environ['https_proxy'] == 'http://127.0.0.1:9'
    assert 'PAIMOS_DEPLOY_KEY' not in os.environ and 'PAIMOS_LEGACY_DEPLOY_KEY' not in os.environ
    assert args[args.index('substituters') + 1] == args[args.index('access-tokens') + 1] == ''
    assert '--no-update-lock-file' in args
    assert args[args.index('flake-registry') + 1] == args[args.index('netrc-file') + 1] == ''
    assert args[-1].startswith('path:') and args[-1].endswith('#sourcePath')
    canary = pathlib.Path(args[-1][5:].split('#')[0])
    copied = json.loads((canary / 'flake.lock').read_text())['nodes']['source']
    node = 'paimos' if copied['locked']['repo'] == 'paimos-legacy' else 'aeon'
    locked = lock['nodes'][lock['nodes'][lock['root']]['inputs'][node]]['locked']
    assert copied['locked'] == locked and copied['flake'] is False
    assert f"github:{locked['owner']}/{locked['repo']}/{locked['rev']}" in (canary / 'flake.nix').read_text()
    record = {'command': 'canary', 'node': node}
else:
    assert args[:3] == ['flake', 'prefetch', '--json'] and len(args) == 4
    node = 'paimos' if '/paimos-legacy?' in args[-1] else 'aeon'
    locked = lock['nodes'][lock['nodes'][lock['root']]['inputs'][node]]['locked']
    assert args[-1] == f"git+ssh://git@github.com/{locked['owner']}/{locked['repo']}?rev={locked['rev']}&allRefs=1"
    ssh = shlex.split(os.environ['GIT_SSH_COMMAND'])
    assert ssh[:3] == ['ssh', '-F', '/dev/null']
    assert all(x in ssh for x in ['IdentitiesOnly=yes', 'BatchMode=yes',
                                  'StrictHostKeyChecking=yes', 'GlobalKnownHostsFile=/dev/null', 'ConnectTimeout=15'])
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
if record['command'] == 'canary':
    sys.exit(1 if os.environ.get('FIXTURE_CANARY_FAIL') == node else 0)
if command == 'curl':
    sys.exit(0 if node in json.loads(os.environ['FIXTURE_PUBLIC']) else 22)
if os.environ.get('FIXTURE_FAIL') == node:
    print('Permission denied; ' + json.dumps(json.loads(os.environ['FIXTURE_KEYS'])), file=sys.stderr)
    sys.exit(1)
if os.environ.get('FIXTURE_BAD_JSON') == node:
    print('malformed fixture')
    sys.exit(0)
print(json.dumps({'hash': 'sha256-wrong' if os.environ.get('FIXTURE_MISMATCH') == node else locked['narHash']}))
'''


def exercise(label, keys=('aeon', 'paimos'), public=(), changed=None, failure=None,
             mismatch=None, bad_json=None, error=None, expected_calls=None, require_keys=False, canary_failure=None):
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
                         FIXTURE_BAD_JSON=bad_json or '', REQUIRE_KEYS=str(require_keys).lower(),
                         FIXTURE_CANARY_FAIL=canary_failure or '')
        result = subprocess.run([os.environ['CONTRACT_BASH'], '-c', script], cwd=root,
                                env=child_env, text=True, capture_output=True, timeout=15)
        output = result.stdout + result.stderr
        assert all(key not in output for key in fixture_keys.values()), label
        assert github_env.read_text() == github_output.read_text() == 'unchanged\n', label
        if error:
            assert result.returncode != 0 and '::error::' in output and error in output, (label, output)
        else:
            assert result.returncode == 0, (label, output)
            assert output.count('::notice::') == sum(c == 'curl' for c, _ in expected_calls), (label, output)
        log = root / 'calls'
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        if not error:
            expected_calls = expected_calls + [('canary', node) for command, node in expected_calls if command == 'nix']
        assert [(c['command'], c['node']) for c in calls] == expected_calls, (label, calls)
        # Success and every failure path remove keys before any later step.
        assert not list(root.glob('paimos-inputs-ssh.*')), label
        assert not list(root.glob('paimos-inputs-canary.*')), label
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
    exercise(f'{node} SSH failure names its secret and redacts diagnostics', failure=node, error='authentication_denied', expected_calls=calls)
for node in ('aeon', 'paimos'):
    for field, value in (('rev', 'main'), ('owner', 'unexpected-owner'), ('repo', 'unexpected-repo'),
                         ('narHash', None), ('rev', 'a' * 40 + '\n'), ('type', 'git'),
                         ('narHash', lock['nodes'][node]['locked']['narHash'] + '\n')):
        changed = copy.deepcopy(lock)
        changed['nodes'][node]['locked'][field] = value
        exercise(f'invalid locked {node}.{field} rejected before its fetch', changed=changed,
                 error='Invalid locked Paimos input', expected_calls=[] if node == 'aeon' else [('nix', 'aeon')])
for node in ('aeon', 'paimos'):
    for mapping in (None, [], 'missing-node'):
        changed = copy.deepcopy(lock)
        changed['nodes'][changed['root']]['inputs'][node] = mapping
        exercise(f'invalid root {node} mapping rejected', changed=changed,
                 error='Invalid locked Paimos input', expected_calls=[] if node == 'aeon' else [('nix', 'aeon')])
renamed = copy.deepcopy(lock)
for node in ('aeon', 'paimos'):
    renamed['nodes'][node + '_2'] = renamed['nodes'].pop(node)
    renamed['nodes'][renamed['root']]['inputs'][node] = node + '_2'
exercise('renamed lock nodes follow root mapping', changed=renamed,
         expected_calls=[('nix', 'aeon'), ('nix', 'paimos')])
retired = copy.deepcopy(lock)
del retired['nodes'][retired['root']]['inputs']['paimos']
exercise('NIX-584 legacy input retired', changed=retired, keys=('aeon',), require_keys=True,
         expected_calls=[('nix', 'aeon')])
exercise('trusted missing legacy key fails even while public', keys=('aeon',), public=('paimos',),
         require_keys=True, error='PAIMOS_LEGACY_DEPLOY_KEY is required on trusted runs', expected_calls=[('nix', 'aeon')])
exercise('trusted missing keys fail even while public', keys=(), public=('aeon', 'paimos'),
         require_keys=True, error='PAIMOS_DEPLOY_KEY is required on trusted runs', expected_calls=[])
exercise('offline github reuse fails closed', canary_failure='aeon', error='Offline github source reuse failed',
         expected_calls=[('nix', 'aeon'), ('nix', 'paimos'), ('canary', 'aeon')])
# Exercise the SSH verifier with real local Git objects, never a network request.
subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'tests',
                '-p', 'test_aeon_pin_gate.py', '-k', 'GitTransportFixtures', '-v'], check=True)
# If Nix is installed, run the actual composite shell against local Git and an
# isolated store/cache. Only its remote URL is redirected; canary evaluations
# use real Nix and the original github lock type. No NixOS config is built.
real_nix = shutil.which('nix')
if real_nix:
    with tempfile.TemporaryDirectory(prefix='ops480-real-nix-') as tmp:
        root = Path(tmp).resolve()  # macOS /var symlinks are invalid store roots.
        source = root / 'source'
        source.mkdir()
        (source / 'fixture.txt').write_text('OPS-480 real Nix source fixture\n')
        author = subprocess.check_output(['git', 'log', '-1', '--format=%an%n%ae'], text=True).splitlines()
        child = dict(os.environ, GIT_AUTHOR_NAME=author[0], GIT_COMMITTER_NAME=author[0],
                     GIT_AUTHOR_EMAIL=author[1], GIT_COMMITTER_EMAIL=author[1],
                     XDG_CACHE_HOME=str(root / 'cache'),
                     http_proxy='http://127.0.0.1:9', https_proxy='http://127.0.0.1:9',
                     all_proxy='http://127.0.0.1:9', HTTP_PROXY='http://127.0.0.1:9',
                     HTTPS_PROXY='http://127.0.0.1:9', ALL_PROXY='http://127.0.0.1:9',
                     no_proxy='', NO_PROXY='')

        def run(args, cwd=None):
            return subprocess.check_output(args, cwd=cwd, env=child, stderr=subprocess.PIPE,
                                           text=True, timeout=30).strip()

        nar_hash = run([real_nix, '--offline', 'hash', 'path', str(source)])
        run(['git', 'init', '-q', str(source)])
        run(['git', '-C', str(source), 'add', 'fixture.txt'])
        run(['git', '-C', str(source), 'commit', '-qm', 'source reuse fixture'])
        revision = run(['git', '-C', str(source), 'rev-parse', 'HEAD'])
        modified = int(run(['git', '-C', str(source), 'log', '-1', '--format=%ct']))
        actual_lock = copy.deepcopy(lock)
        for node in ('aeon', 'paimos'):
            actual_lock['nodes'][node]['locked'].update(rev=revision, narHash=nar_hash, lastModified=modified)
        (root / 'flake.lock').write_text(json.dumps(actual_lock))
        binary = root / 'bin'
        binary.mkdir()
        wrapper = binary / 'nix'
        wrapper.write_text(f'#!{sys.executable}\n' + r'''
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
prefix = [os.environ['FIXTURE_REAL_NIX'], '--offline', '--store', os.environ['FIXTURE_STORE'],
          '--option', 'substituters', '', '--option', 'access-tokens', '',
          '--option', 'flake-registry', '']
if args[:3] == ['flake', 'prefetch', '--json']:
    # Redirect only the fixed remote. Everything else uses real Nix.
    assert args[-1].startswith('git+ssh://git@github.com/inspr-at/')
    args[-1] = 'git+file://' + os.environ['FIXTURE_SOURCE'] + '?' + args[-1].split('?', 1)[1]
else:
    assert args[0] == 'eval' and '--offline' in args
    assert not list(pathlib.Path(os.environ['RUNNER_TEMP']).glob('paimos-inputs-ssh.*'))
    assert os.environ['GIT_SSH_COMMAND'] == 'false'
    args += ['--eval-store', os.environ['FIXTURE_STORE']]
result = subprocess.run(prefix + args, capture_output=True)
if result.returncode:
    # All fixture inputs are synthetic, but still keep diagnostics value-free.
    print('real Nix fixture subprocess failed', file=sys.stderr)
sys.stdout.buffer.write(result.stdout)
sys.exit(result.returncode)
''')
        wrapper.chmod(0o700)
        child.update(PATH=str(binary) + os.pathsep + child['PATH'], RUNNER_TEMP=str(root),
                     PAIMOS_DEPLOY_KEY=fixture_keys['aeon'],
                     PAIMOS_LEGACY_DEPLOY_KEY=fixture_keys['paimos'], REQUIRE_KEYS='true',
                     FIXTURE_REAL_NIX=real_nix, FIXTURE_STORE=str(root / 'store'),
                     FIXTURE_SOURCE=str(source))
        try:
            output = run([os.environ['CONTRACT_BASH'], '-c', script], cwd=root)
        except subprocess.CalledProcessError as error:
            raise AssertionError('real Nix composite/canary fixture failed: ' + error.stderr) from None
        assert output.count('Verified offline github source reuse') == 2
        assert all(key not in output for key in fixture_keys.values())
        assert not list(root.glob('paimos-inputs-ssh.*'))
        assert not list(root.glob('paimos-inputs-canary.*'))
        print('OPS-480 real Nix Git prefetch + locked github reuse: OK (isolated store/cache; no network)')
else:
    print('OPS-480 real Nix fixture: SKIP (Nix unavailable; composite action runs the canary on every Nix pin)')
print('OPS-480 private Paimos input contracts: PASS (offline; synthetic keys)')
PY
