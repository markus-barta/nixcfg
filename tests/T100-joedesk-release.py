#!/usr/bin/env python3
"""OPS-354 release-set consistency and evaluation-only refactor proof."""
import argparse
import json
import os
import hashlib
import pathlib
import re
import subprocess
import tempfile
import copy
import importlib.util
import shutil
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = ROOT / 'hosts/csb0/joedesk-release.json'
BASELINE = 'ed5e43d6600b6b610a8c4483eba2627f00b4fd58'
# OPS-408: exact pre-r17 runtime, including the release-set wiring.
HSB0_BASELINE = "2eb3953e076b5b35769ddc1418080cd17e35d2ff"
HSB0_IMAGE = 'hsb0-joe-board-pusher:household-v2-switch-set-r16d-202610201800'
CANDIDATE_IMAGE = 'hsb0-joe-board-pusher:household-v2-switch-set-r17c-202610202345'
LEGACY = 'db621bf7f00a4c609b0930ef7d5020f3c8935ee9'
PUBLISHED = '6eacd6c707386cabe8245e1f97df2ef93965b394'
PUBLISHED_TREE = 'f2080e9baf5e2eae59f663bbbc75a39a25bde493'
CONTRACT_SET_SHA256 = '000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5'
CONTRACTS_JSON_SHA256 = '5c20c38be4602f6c142ece1c1abc65172306d504aa0a74d098e10bb15f78ef17'
SHA = re.compile(r'[0-9a-f]{64}')
REV = re.compile(r'[0-9a-f]{40}')


def require(value, reason):
    if not value:
        raise AssertionError(reason)


# A changed hosts/hsb0 file outside the pins may move on under variant B only if neither version names JoeDesk
# or the LIVE gateway surface (TRADING_MODE, the live/paper-live ports, the gateway, stager socket, mailbox).
JOEDESK_TOKENS = re.compile(r'joe|paper-desk|paperdesk|joed|trading_mode|(?<![0-9])400[13](?![0-9])|ib-gateway|ibgateway'
                            r'|stage\.sock|agent-mailbox|agentmailbox', re.I)
# Pinned byte-equal to the recorded revision: the JoeDesk services, the pusher tree, and every imported hsb0
# module (composeStack.spec is a deep-merged attrset, so any of them could add a second gateway service).
JOEDESK_HSB0 = ('hosts/hsb0/configuration.nix', 'hosts/hsb0/docker/joe-board-pusher/', 'hosts/hsb0/docker/compose-spec.nix',
                'hosts/hsb0/hardware-configuration.nix', 'hosts/hsb0/disk-config.zfs.nix', 'hosts/hsb0/lg-devmode-renew.nix',
                'hosts/hsb0/lg-devmode-renew.py', 'hosts/hsb0/runbook-secrets.age')


def git_changed_paths(root, rel, rev):
    # -z: NUL-terminated, never quoted. --no-renames: a rename is a delete plus an add, so a file that leaves
    # a pinned tree is listed under its source path too. Literal pathspec, paths relative to the repo root.
    out = subprocess.check_output(['git', '--literal-pathspecs', 'diff', '-z', '--no-renames', '--no-relative', '--no-ext-diff',
                                   '--name-only', rev, 'HEAD', '--', rel], cwd=root)
    return [p.decode('utf-8', 'surrogateescape') for p in out.split(b'\0') if p]


def git_read_blob(root, spec):
    # The file's text, or None only when the path is absent from a valid commit; anything else fails.
    rev, path = spec.split(':', 1)
    subprocess.run(['git', 'rev-parse', '--verify', '--quiet', rev + '^{commit}'], cwd=root, check=True, stdout=subprocess.DEVNULL)
    out = subprocess.check_output(['git', '--literal-pathspecs', 'ls-tree', '-z', '--full-tree', rev, '--', path], cwd=root)
    entries = [e for e in out.split(b'\0') if e]
    if not entries:
        # No tree entry in a valid commit; `cat-file -e` must agree, or the lookup itself is broken.
        absent = subprocess.run(['git', 'cat-file', '-e', spec], cwd=root, stderr=subprocess.DEVNULL).returncode != 0
        require(absent, 'blob lookup disagrees for ' + path)
        return None
    require(len(entries) == 1, 'ambiguous tree entry for ' + path)
    meta, name = entries[0].split(b'\t', 1)
    mode, kind, oid = meta.decode().split(' ')
    require(name.decode('utf-8', 'surrogateescape') == path, 'tree entry path mismatch for ' + path)
    require(kind == 'blob' and mode in ('100644', '100755'), 'variant B cannot judge a ' + mode + ' ' + kind + ' entry: ' + path)
    # Undecodable bytes become U+FFFD; the ASCII tokens still match, so a binary is judged, not a crash.
    return subprocess.check_output(['git', 'cat-file', 'blob', oid], cwd=root).decode('utf-8', 'replace')


def hsb0_runtime(release, hsb0_config, executor_module, tree_of, changed_paths=None, read_blob=None):
    # The stager image must equal the effective pusher image of the deployed selection.
    stage_image = re.search(r'services\.joe-household-v2-stage = \{.*?image = ([^;]+);', hsb0_config, re.S)[1]
    current = release['sets']['current']
    if 'joeRelease' in hsb0_config:
        # hsb0 follows the release set: allowed only for current or v2. Under `previous`
        # it would select the flat-net downstream pins, so the v1 rollback must be variant B.
        require(release['active'] in ('current', 'v2'), 'with active = previous hsb0 must be the variant B pre-cutover tree')
        require(stage_image == 'joeSet.pusher.image', 'stager must follow the release-set pusher pin')
        return 'release-set'
    # OPS-354 variant B rollback: hosts/hsb0 and modules/paper-desk-executor are restored to the
    # recorded pre-cutover revision, which pins the recorded r16d switch set literally.
    require(release['active'] == 'previous', 'only the v1 rollback may restore hsb0 to the pre-cutover tree')
    recorded = current['pusher']['image']
    require(recorded == current['executor']['image'] == HSB0_IMAGE, 'variant B record must be the r16d switch set')
    pusher = re.search(r'services\.joe-board-pusher = \{\s*build = [^;]+;\s*image =\s*if joeHouseholdV2StageEnabled then\s*"([^"]+)"', hsb0_config)
    executor_default = re.search(r'image = lib\.mkOption \{[^}]*?default = "([^"]+)";', executor_module, re.S)
    require('joeHouseholdV2StageEnabled = true;' in hsb0_config, 'variant B keeps the r16d stager enabled')
    require(pusher and pusher[1] == recorded, 'variant B pusher must be the recorded r16d image')
    require(stage_image == json.dumps(recorded), 'variant B stager must be the recorded r16d image')
    require(executor_default and executor_default[1] == recorded, 'variant B executor default must be the recorded r16d image')
    rev = current.get('retention', {}).get('hsb0_pre_cutover_nixcfg_rev', '')
    require(REV.fullmatch(rev or ''), 'variant B needs the recorded pre-cutover hsb0 revision')
    rel = 'modules/paper-desk-executor'
    require(tree_of('HEAD:' + rel) == tree_of(rev + ':' + rel), 'variant B must restore the recorded pre-cutover ' + rel + ' tree')
    # hosts/hsb0: the pinned surface (configuration.nix with the pusher/stager/executor services, the pusher
    # source tree, the imported hsb0 modules) must equal the recorded pre-cutover revision. Other hsb0 files may
    # move on (e.g. OPS-407's fritz-guest-uplink.nix) only if neither version mentions a JOEDESK_TOKENS token.
    require(changed_paths is not None and read_blob is not None, 'variant B needs the hosts/hsb0 walker')
    for path in changed_paths('hosts/hsb0', rev):
        require(not any(path == p or (p.endswith('/') and path.startswith(p)) for p in JOEDESK_HSB0),
                'variant B must restore the recorded pre-cutover JoeDesk surface: ' + path)
        require(not path.endswith('.age'), 'variant B never reads ciphertext; a changed .age file must be restored: ' + path)
        blobs = [read_blob(version + ':' + path) for version in ('HEAD', rev)]
        require(any(b is not None for b in blobs), 'variant B: changed path absent in both versions (walker mismatch): ' + path)
        for text in blobs:
            require(text is None or not JOEDESK_TOKENS.search(text),
                    'variant B: a changed hosts/hsb0 file mentions JoeDesk: ' + path)
    return 'variant-b'


def variant_b_regressions():
    # OPS-354 (c): the rollback commit restores hsb0 to its pre-cutover tree; T100 runs in
    # rollback-joedesk's cross-host switch before `just switch` and must accept exactly that state.
    release = json.loads(RELEASE.read_text())
    rev = release['sets']['current']['retention']['hsb0_pre_cutover_nixcfg_rev']
    git = lambda *a: subprocess.check_output(['git', *a], cwd=ROOT, text=True)
    restored = git('show', rev + ':hosts/hsb0/configuration.nix')
    restored_module = git('show', rev + ':modules/paper-desk-executor/default.nix')
    same = lambda spec: spec.split(':', 1)[1]
    following = 'let joeRelease = x; in services.joe-household-v2-stage = { image = joeSet.pusher.image; };'
    rollback = copy.deepcopy(release); rollback['active'] = 'previous'
    changed = lambda *paths: (lambda rel, rev: list(paths))
    blob = lambda text: (lambda spec: text)
    unchanged = (changed(), blob(None))
    require(hsb0_runtime(rollback, restored, restored_module, same, *unchanged) == 'variant-b', 'variant B rollback state rejected')
    for selected in ('current', 'v2'):
        fixture = copy.deepcopy(release); fixture['active'] = selected
        require(hsb0_runtime(fixture, following, restored_module, same) == 'release-set', 'release-set hsb0 rejected')
    r17 = restored.replace('r16d-202610201800', 'r17c-202610202345')
    negatives = [
        (rollback, following, restored_module, same),  # release-set hsb0 under previous = flat-net pins
        (dict(release, active='v2'), restored, restored_module, same),
        (dict(release, active='current'), restored, restored_module, same),
        (rollback, r17, restored_module, same),
        (rollback, restored, restored_module.replace('r16d-202610201800', 'r17c-202610202345'), same),
        (rollback, restored.replace('joeHouseholdV2StageEnabled = true;', 'joeHouseholdV2StageEnabled = false;'), restored_module, same),
        (rollback, restored, restored_module, lambda spec: ('0' * 40) if spec.startswith('HEAD:') else spec),
        (rollback, 'let joeRelease = x; in services.joe-household-v2-stage = { image = "literal"; };', restored_module, same),
    ]
    surface, content = 'JoeDesk surface', 'mentions JoeDesk'
    scoped = [  # (changed paths, blob, reason): the pinned surface or JoeDesk/LIVE content must not move under previous
        (changed('hosts/hsb0/configuration.nix'), blob(''), surface),
        (changed('hosts/hsb0/docker/joe-board-pusher/pusher.mjs'), blob(''), surface),
        (changed('hosts/hsb0/docker/joe-board-pusher/README.md'), blob(''), surface),
        (changed('hosts/hsb0/docker/compose-spec.nix'), blob(''), surface),
        (changed('hosts/hsb0/hardware-configuration.nix'), blob(''), surface),
        (changed('hosts/hsb0/disk-config.zfs.nix'), blob(''), surface),
        (changed('hosts/hsb0/lg-devmode-renew.nix'), blob(''), surface),
        (changed('hosts/hsb0/lg-devmode-renew.py'), blob(''), surface),
        (changed('hosts/hsb0/runbook-secrets.age'), blob(''), surface),
        (changed('hosts/hsb0/archive/other.age'), blob(''), 'ciphertext'),
        (changed('hosts/hsb0/fritz-guest-uplink.nix'), blob('mounts /var/lib/joe-board-pusher'), content),
        (changed('hosts/hsb0/new-unit.nix'), blob('paper-desk executor helper'), content),
        (changed('hosts/hsb0/new-unit.nix'), blob(None), 'absent in both'),
    ] + [(changed('hosts/hsb0/fritz-guest-uplink.nix'), blob(text), content) for text in (
        'environment = [ "TRADING_MODE=live" ];', 'ports = [ "4001:4001" ];', 'ports = [ "127.0.0.1:4003:4003" ];',
        'services.ib-gateway-2 = {};', 'ibGateway.port = 1;', 'volumes = [ "/run/joe/stage.sock" ];',
        'services.agent-mailbox = {};', 'agentMailbox.enable = true;')]
    for fixture, config, module, tree_of in negatives:
        try:
            hsb0_runtime(fixture, config, module, tree_of, *unchanged)
        except AssertionError:
            continue
        raise AssertionError('invalid hsb0 runtime state passed')
    rejects(lambda: hsb0_runtime(rollback, restored, restored_module, same), 'needs the hosts/hsb0 walker')
    for changed_paths, read_blob, reason in scoped:
        rejects(lambda: hsb0_runtime(rollback, restored, restored_module, same, changed_paths, read_blob), reason)
    # An unrelated hsb0 file (no JoeDesk content in either version) may move on under the v1 rollback.
    for text in ('neigh pin for 10.255.5.2', 'port 14001 and 40010 are not the gateway'):
        require(hsb0_runtime(rollback, restored, restored_module, same, changed('hosts/hsb0/fritz-guest-uplink.nix'), blob(text)) == 'variant-b',
                'variant B must allow an unrelated hsb0 file to move on')
    walked = walker_regressions(rollback, restored, restored_module)
    print('variant_b_rollback=accepted negatives=%d walker_cases=%d' % (len(negatives) + len(scoped) + 1, walked))


def rejects(call, reason):
    try:
        call()
    except AssertionError as error:
        require(reason in str(error), 'variant B rejected for the wrong reason: %s (expected %r)' % (error, reason))
        return
    raise AssertionError('variant B accepted a state it must reject: ' + reason)


def walker_regressions(rollback, restored, restored_module):
    # JOED gate (Medium): drive the production walker (git_changed_paths + git_read_blob) over a scratch repo,
    # isolated from the user's git config, so renames, unquoted paths and absent blobs are proven, not stubbed.
    same = lambda spec: spec.split(':', 1)[1]
    with tempfile.TemporaryDirectory() as scratch:
        repo = pathlib.Path(scratch)
        env = {'PATH': os.environ['PATH'], 'HOME': scratch, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
               'GIT_AUTHOR_NAME': 't100', 'GIT_AUTHOR_EMAIL': 't100@invalid', 'GIT_COMMITTER_NAME': 't100', 'GIT_COMMITTER_EMAIL': 't100@invalid'}
        git = lambda *a: subprocess.run(['git', *a], cwd=repo, env=env, check=True, capture_output=True).stdout.decode().strip()
        def write(rel, data):
            path = repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data if isinstance(data, bytes) else data.encode())
        git('init', '-q')
        base_files = {
            'hosts/hsb0/docker/joe-board-pusher/paper-account.mjs': 'export const account = 1;\n',
            'hosts/hsb0/docker/joe-board-pusher/pä.mjs': 'export const x = 1;\n',
            'hosts/hsb0/old-helper.nix': '{ services.ib-gateway.ports = []; }\n',
            'hosts/hsb0/ünrelated.txt': 'a\n',
            'hosts/hsb0/fritz-guest-uplink.nix': 'neigh pin\n',
        }
        for rel, text in base_files.items():
            write(rel, text)
        git('add', '-A'); git('commit', '-q', '-m', 'recorded')
        base = git('rev-parse', 'HEAD')
        fixture = copy.deepcopy(rollback)
        fixture['sets']['current']['retention']['hsb0_pre_cutover_nixcfg_rev'] = base
        run = lambda: hsb0_runtime(fixture, restored, restored_module, same,
                                   lambda rel, rev: git_changed_paths(repo, rel, rev), lambda spec: git_read_blob(repo, spec))
        cases = [  # (name, mutation, expected rejection reason or None = accepted)
            ('rename out of the pusher tree', lambda: git('mv', 'hosts/hsb0/docker/joe-board-pusher/paper-account.mjs', 'hosts/hsb0/docker/escaped-paper-account.mjs'), 'JoeDesk surface'),
            ('non-ASCII rename out of the pusher tree', lambda: git('mv', 'hosts/hsb0/docker/joe-board-pusher/pä.mjs', 'hosts/hsb0/ä.mjs'), 'JoeDesk surface'),
            ('token only in the recorded revision', lambda: git('rm', '-q', 'hosts/hsb0/old-helper.nix'), 'mentions JoeDesk'),
            ('LIVE port added to an allowed file', lambda: write('hosts/hsb0/fritz-guest-uplink.nix', 'ports = [ "4001:4001" ];\n'), 'mentions JoeDesk'),
            ('binary with a token', lambda: write('hosts/hsb0/blob.bin', b'\xff\xfe\x00TRADING_MODE=live\x00'), 'mentions JoeDesk'),
            ('changed ciphertext', lambda: write('hosts/hsb0/archive/old.age', 'age-encryption.org/v1 placeholder\n'), 'ciphertext'),
            ('symlink', lambda: (repo / 'hosts/hsb0/link').symlink_to('fritz-guest-uplink.nix'), 'cannot judge'),
            ('unrelated non-ASCII edit', lambda: write('hosts/hsb0/ünrelated.txt', 'b\n'), None),
            ('token-free binary', lambda: write('hosts/hsb0/logo.png', b'\x89PNG\r\n\x1a\n\xff\xfe\x00\x01'), None),
            ('unrelated edit of the allowed file', lambda: write('hosts/hsb0/fritz-guest-uplink.nix', 'neigh pin for 10.255.5.2\n'), None),
        ]
        for name, mutate, reason in cases:
            git('checkout', '-q', '--detach', base)
            mutate()
            git('add', '-A'); git('commit', '-q', '-m', name)
            if reason:
                rejects(run, reason)
            else:
                require(run() == 'variant-b', 'variant B must accept: ' + name)
        # Without --no-renames the escaped file is listed only at its token-free destination (the gate's bypass).
        git('checkout', '-q', '--detach', base); cases[0][1](); git('commit', '-q', '-m', 'rename')
        require(git('diff', '--name-only', '-M', base, 'HEAD') == 'hosts/hsb0/docker/escaped-paper-account.mjs', 'rename fixture must exercise rename detection')
        # A path in neither version, an unknown revision and a tree are walker errors, never an empty blob.
        require(git_read_blob(repo, base + ':hosts/hsb0/never-there.nix') is None, 'absent path must read as None')
        for spec in ('0' * 40 + ':hosts/hsb0/fritz-guest-uplink.nix', base + ':hosts/hsb0/docker'):
            try:
                git_read_blob(repo, spec)
            except (subprocess.CalledProcessError, AssertionError):
                continue
            raise AssertionError('walker read an invalid spec as a blob: ' + spec)
        return len(cases) + 3


def check(source=None):
    release = json.loads(RELEASE.read_text())
    require(release['schema'] == 'nixcfg.joedesk-release-set.v1', 'release set schema')
    require(set(release['sets']) == {'current', 'v2', 'previous'}, 'three explicit release sets')
    for name in ('pusher', 'executor'):
        require(release['sets']['current'][name]['image'] == HSB0_IMAGE, name + ': current image must be the r16d switch set')
    hsb0_config = (ROOT / 'hosts/hsb0/configuration.nix').read_text()
    executor_module = (ROOT / 'modules/paper-desk-executor/default.nix').read_text()
    git_out = lambda *a: subprocess.check_output(['git', *a], cwd=ROOT, text=True)
    hsb0_runtime(release, hsb0_config, executor_module, lambda spec: git_out('rev-parse', spec).strip(),
                 lambda rel, rev: git_changed_paths(ROOT, rel, rev), lambda spec: git_read_blob(ROOT, spec))
    fixture = (ROOT / 'tests/paper-desk-executor-eval.nix').read_text()
    require(CANDIDATE_IMAGE in fixture, 'executor fixture must identify the r17 candidate')
    # The executor eval fixture must evaluate to the EFFECTIVE hsb0 pusher image of this release state.
    block = re.search(r'joe-board-pusher\.image =\s*(let.*?in\s*release\.sets\.\$\{selected\}\.pusher\.image);', fixture, re.S)
    require(block, 'executor fixture must select the effective hsb0 runtime set')
    expr = block[1].replace('../hosts/csb0/joedesk-release.json', str(RELEASE))
    fixture_image = subprocess.check_output(['nix', 'eval', '--impure', '--raw', '--expr', expr], cwd=ROOT, text=True).strip()
    effective = release['sets']['current' if release['active'] == 'previous' else release['active']]['pusher']['image']
    require(fixture_image == effective, 'executor fixture image differs from the effective hsb0 pusher image')
    active = release['sets'][release['active']]
    lock = json.loads((ROOT / 'flake.lock').read_text())
    require(active['board']['rev'] == lock['nodes']['joedesk']['locked']['rev'], 'active board disagrees with lock')
    url_rev = re.search(r'joedesk = \{\s*url = \"github:markus-barta/joedesk/([0-9a-f]{40})\";', (ROOT / 'flake.nix').read_text())[1]
    require(active['board']['rev'] == url_rev, 'active source disagrees with flake URL')
    for item in release['sets'].values():
        board = item['board']
        require(REV.fullmatch(board['rev']), 'board revision is not immutable')
        if board['data_schema'] == 'v1':
            require(board['rev'] == LEGACY and board['version_scheme'] == 'calendar' and board['version'] == '26.09.21.12.00' and board['release_sequence'] == 23 and board['tag'] is None, 'legacy anchor/history changed')
            require(item['contracts'] is None and board['public_health'] is False, 'v1 has no v2 contract or public health')
        else:
            require(board['data_schema'] == 'v2', 'unknown board data schema')
            require(board['rev'] == PUBLISHED, 'published v2 revision mismatch')
            require(board['version_scheme'] == 'inspr-calver-3' and board['version'] == '261021015923.0.0' and board['release_sequence'] == 26, 'published canonical CalVer3 metadata mismatch')
            contracts = item['contracts']
            digest = contracts['contract_set_sha256']
            require(SHA.fullmatch(digest) and digest == CONTRACT_SET_SHA256, 'published contract digest mismatch')
            require(contracts['manifest_revision'] == 9, 'published contract manifest revision mismatch')
            expected = {'data': ['inspr.joe.household.v2'], 'history': ['inspr.joe.household.history.v2'], 'results': ['inspr.joe.household.results.v2'], 'fleet-config': ['inspr.joe.fleet-config.v1'], 'healthz': ['inspr.joe.healthz.v2']}
            require(contracts['compatibility'] == expected and contracts['participants']['board']['accepts'] == expected, 'exact compatibility IDs required')
            for participant in ('pusher', 'executor'):
                require(contracts['participants'][participant]['required_contract_set_sha256'] == digest, 'participant digest mismatch')
        if item is active:
            for name in ('pusher', 'executor'):
                require(item[name] and REV.fullmatch(item[name]['nixcfg_rev']) and REV.fullmatch(item[name]['source_tree']) and item[name]['image'], 'active downstream pins missing')
            require(board['image'] == 'csb0-joe-board:source-' + board['rev'], 'active board image pin')
            require(item['pusher']['image'] == item['executor']['image'], 'executor runtime must match the pinned pusher image')
    if source:
        candidate_version = json.loads((source / 'release.json').read_text())
        for field in ('version_scheme', 'version', 'release_sequence'):
            require(release['sets']['v2']['board'][field] == candidate_version[field], 'candidate version metadata mismatch')
        contracts_bytes = (source / 'release/contracts.json').read_bytes()
        require(hashlib.sha256(contracts_bytes).hexdigest() == CONTRACTS_JSON_SHA256, 'published contracts.json hash mismatch')
        expected = json.loads(contracts_bytes)
        require(release['sets']['v2']['contracts'] == expected, 'candidate differs from authoritative contracts.json')
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        require(release['sets']['v2']['board']['rev'] == revision, 'candidate revision mismatch')
        tree = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD^{tree}'], text=True).strip()
        require(tree == PUBLISHED_TREE, 'published source tree mismatch')
    return release


def evaluation_proof():
    # Compare the release refactor with the recorded baseline declarations against the SAME
    # compose spec. Item 1's intentional routing change is outside this proof.
    # Stubs affect only external source/service paths, identically on both sides.
    update = 'update = a: b: a // builtins.mapAttrs (n: v: if builtins.hasAttr n a && builtins.isAttrs a.${n} && builtins.isAttrs v then update a.${n} v else v) b;'
    args = '''{ lib = { recursiveUpdate = update; cleanSourceWith = _: "/nix/store/pusher-stand-in"; mkOption = x: x; }; pkgs = {}; config.nixcfg = { paperDeskExecutor.serviceSpec = {}; agentMailbox.serviceSpec = {}; }; inputs.joedesk = { outPath = "/nix/store/joedesk-stand-in"; rev = "''' + LEGACY + '''"; }; }'''
    for relative in ('hosts/csb0/configuration.nix',):
        path = ROOT / relative
        before = subprocess.check_output(['git', 'show', BASELINE + ':' + relative], cwd=ROOT, text=True)
        before = before.replace('import ./docker/compose-spec.nix', 'import ' + str(path.parent / 'docker/compose-spec.nix'))
        with tempfile.TemporaryDirectory(prefix='ops354-eval-') as folder:
            old = pathlib.Path(folder) / 'before.nix'
            old.write_text(before)
            values = []
            for file in (old, path):
                expr = 'let ' + update + ' in (import ' + str(file) + ' ' + args + ').nixcfg.composeStack.spec'
                values.append(subprocess.check_output(['nix', 'eval', '--impure', '--json', '--expr', expr], cwd=ROOT))
            require(values[0] == values[1], relative + ': rendered spec changed in release refactor')
    current = check()['sets']['current']
    actual_image = subprocess.check_output(['nix', 'eval', '--impure', '--raw', '--expr', '(import ' + str(ROOT / 'modules/paper-desk-executor/default.nix') + ' { config = {}; pkgs = {}; lib.mkOption = x: x; }).options.nixcfg.paperDeskExecutor.image.default'], cwd=ROOT, text=True)
    require(current['executor']['image'] == actual_image == HSB0_IMAGE, 'executor default must use the r16d switch set')
    for name in ('pusher', 'executor'):
        pin = current[name]
        tree = subprocess.check_output(['git', 'rev-parse', pin['nixcfg_rev'] + ':' + pin['source_path']], cwd=ROOT, text=True).strip()
        require(tree == pin['source_tree'], 'recorded source tree mismatch')
    # Compare hsb0 with the recorded exact main, including its stage and local
    # mailbox, against 2eb3953e and its live r16d switch set.
    hsb0_evaluation_proof()
    print('release_refactor=byte-identical-static-specs executor_default=r16d-main-equal linux_toplevel_drvPath=pending')


def hsb0_evaluation_proof():
    # Reuse the real module evaluator with real Linux packages in a disposable
    # local store. This only evaluates derivations; it never builds or contacts
    # the daemon, network or any host. Source drvPaths bind the closure bytes.
    harness = (ROOT / 'tests/paper-desk-executor-eval.nix').read_text()
    start = harness.index('    specialArgs.pkgs = {')
    end = harness.index('    modules = [', start)
    harness = harness[:start] + '    specialArgs.pkgs = import <nixpkgs> { system = "x86_64-linux"; };\n' + harness[end:]
    harness = harness.replace(
        'extraRestartTriggers = lib.mkOption { type = lib.types.listOf lib.types.str; };',
        'extraRestartTriggers = lib.mkOption { type = lib.types.listOf lib.types.anything; };')
    # Feed the actual host executor options into the real module evaluator too.
    harness = harness.replace('''          nixcfg.paperDeskExecutor = {
            enable = true;
          }''', '''          nixcfg.paperDeskExecutor = (import @ROOT@/hosts/hsb0/configuration.nix {
            inherit lib; pkgs = import <nixpkgs> { system = "x86_64-linux"; }; config = cfg; inputs = {};
          }).nixcfg.paperDeskExecutor''')
    harness = harness[:harness.index('if tailnetContract then\n')] + '''{
      image = cfg.nixcfg.paperDeskExecutor.image;
      executorOptions = builtins.removeAttrs cfg.nixcfg.paperDeskExecutor [ "serviceSpec" ];
      service = cfg.nixcfg.paperDeskExecutor.serviceSpec;
      systemd = cfg.systemd;
      firewall = cfg.networking.firewall;
      users = cfg.users;
      triggers = map (drv: { sourcePath = toString drv; drvPath = drv.drvPath; }) cfg.nixcfg.composeStack.extraRestartTriggers;
      hostCompose = (import @ROOT@/hosts/hsb0/configuration.nix {
        inherit lib; pkgs = import <nixpkgs> { system = "x86_64-linux"; }; config = cfg; inputs = {};
      }).nixcfg.composeStack.spec;
    }
    '''
    with tempfile.TemporaryDirectory(prefix='ops354-hsb0-eval-') as folder:
        folder = pathlib.Path(folder).resolve()
        main = folder / 'main'
        main.mkdir()
        paths = ['hosts/csb0/joedesk-release.json', 'modules/paper-desk-executor', 'modules/tailnet-peers',
                 'modules/agent-mailbox', 'modules/joe-results-producer',
                 'modules/ib-gateway-session', 'hosts/hsb0/configuration.nix',
                 'hosts/hsb0/docker/compose-spec.nix', 'hosts/hsb0/docker/joe-board-pusher']
        archive = subprocess.check_output(['git', 'archive', HSB0_BASELINE, *paths], cwd=ROOT)
        subprocess.run(['tar', '-xf', '-', '-C', str(main)], input=archive, check=True)
        values = []
        for name, source in (('main', main), ('merged', ROOT)):
            expression = folder / (name + '.nix')
            source_harness = harness.replace('../hosts/', str(source / 'hosts') + '/')
            expression.write_text(source_harness.replace('../modules/', str(source / 'modules') + '/').replace('@ROOT@', str(source)))
            values.append(subprocess.check_output([
                'nix', 'eval', '--offline', '--store', str(folder / 'store'), '--impure',
                '--json', '--file', str(expression), '--apply', 'f: f {}'], cwd=ROOT))
        actual = json.loads(values[1])
        for name in ('joe-board-pusher', 'paper-desk-executor', 'joe-household-v2-stage'):
            require(actual['hostCompose']['services'][name]['image'] == HSB0_IMAGE, name + ': evaluated host image must be the r16d switch set')
        require(actual['image'] == HSB0_IMAGE, 'evaluated executor image must be the r16d switch set')
        baseline = json.loads(values[0])
        # The unchanged build-context policy necessarily captures new .mjs bytes.
        # Nothing else may change while current.data_schema remains v1.
        build_changes = []
        for name, service in actual['hostCompose']['services'].items():
            previous = baseline['hostCompose']['services'][name]
            if service.get('build') != previous.get('build'):
                build_changes.append(name)
            service.pop('build', None)
            previous.pop('build', None)
        require(sorted(build_changes) == ['joe-board-pusher', 'joe-household-v2-stage'], 'only pusher-source build contexts may change')
        require(baseline == actual, 'v1 runtime differs from 2eb3953e: image, service, units, firewall, users, executor derivations or compose')
        pusher = actual['hostCompose']['services']['joe-board-pusher']
        require(pusher == {
            'container_name': 'joe-board-pusher', 'restart': 'unless-stopped', 'network_mode': 'host',
            'env_file': ['/run/agenix/hsb0-ib-desk-env'], 'image': HSB0_IMAGE, 'pull_policy': 'never',
            'labels': ['com.centurylinklabs.watchtower.enable=false', 'traefik.enable=false'],
            'environment': ['TZ=Europe/Vienna', 'JOE_PUSH_INTERVAL_SEC=30',
                'JOE_EXECUTOR_CLIENT_IDS=[705,700]', 'JOE_V2_STAGE_SOCKET=/run/joe-household-v2/stage.sock'],
            'volumes': ['/run/agenix/joe-board-push-token:/run/secrets/joe-board-push-token:ro',
                '/var/lib/joe-board-pusher:/var/lib/joe-board-pusher:rw', '/var/lib/paper-desk-executor:/var/lib/paper-desk-executor:ro',
                '/run/joe-household-v2:/run/joe-household-v2:rw'],
        }, 'v1 complete pusher runtime golden changed')
        candidate = folder / 'candidate'
        for relative in paths:
            source_path, target = ROOT / relative, candidate / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source_path.is_dir():
                shutil.copytree(source_path, target, ignore=shutil.ignore_patterns('node_modules', '__pycache__'))
            else:
                shutil.copy2(source_path, target)
        selected = check()
        selected['active'] = 'v2'
        for participant in ('pusher', 'executor'):
            selected['sets']['v2'][participant] = copy.deepcopy(selected['sets']['current'][participant])
            selected['sets']['v2'][participant]['image'] = CANDIDATE_IMAGE
        (candidate / 'hosts/csb0/joedesk-release.json').write_text(json.dumps(selected))
        expression = folder / 'v2.nix'
        expression.write_text(harness.replace('../modules/', str(candidate / 'modules') + '/')
                              .replace('../hosts/', str(candidate / 'hosts') + '/').replace('@ROOT@', str(candidate)))
        activated = json.loads(subprocess.check_output([
            'nix', 'eval', '--offline', '--store', str(folder / 'store'), '--impure',
            '--json', '--file', str(expression), '--apply', 'f: f {}'], cwd=ROOT))
        services = activated['hostCompose']['services']
        for name in ('joe-board-pusher', 'paper-desk-executor', 'joe-household-v2-stage'):
            require(services[name]['image'] == CANDIDATE_IMAGE, name + ': v2 must select r17')
        require(activated['image'] == CANDIDATE_IMAGE, 'v2 executor option must select r17')
        require('JOE_PUSH_SCHEMA=inspr.joe.household.v2' in services['joe-board-pusher']['environment'], 'v2 schema activation missing')
        require(services['joe-board-pusher']['volumes'] == pusher['volumes'] + [
            '/var/lib/joe-board-pusher/v2:/var/lib/joe-board-pusher/v2:ro'], 'v2 exact nested read-only mount missing')
        stage = services['joe-household-v2-stage']
        require(stage['network_mode'] == 'none' and stage['read_only'] is True
                and '/var/lib/joe-board-pusher/v2:/var/lib/joe-board-pusher/v2:rw' in stage['volumes'], 'stager isolation changed')
        expected_stage = copy.deepcopy(actual['hostCompose']['services']['joe-household-v2-stage'])
        expected_stage['image'] = CANDIDATE_IMAGE
        require({k: v for k, v in stage.items() if k != 'build'} == expected_stage, 'v2 stager behavior changed beyond its selected image')
        # Disabling staging while v2 is active must not select an old v1 sender
        # or remove the read-only bind. The committed cursor still governs POSTs.
        host_path = candidate / 'hosts/hsb0/configuration.nix'
        host_path.write_text(host_path.read_text().replace('joeHouseholdV2StageEnabled = true;', 'joeHouseholdV2StageEnabled = false;'))
        disabled = json.loads(subprocess.check_output([
            'nix', 'eval', '--offline', '--store', str(folder / 'store'), '--impure',
            '--json', '--file', str(expression), '--apply', 'f: f {}'], cwd=ROOT))
        services = disabled['hostCompose']['services']
        require('joe-household-v2-stage' not in services, 'disabled stager remains present')
        require(services['joe-board-pusher']['image'] == disabled['image'] == CANDIDATE_IMAGE, 'disabled stager selected a v1-only runtime')
        require('JOE_PUSH_SCHEMA=inspr.joe.household.v2' in services['joe-board-pusher']['environment'], 'disabled stager removed v2 mode')
        require('/var/lib/joe-board-pusher/v2:/var/lib/joe-board-pusher/v2:ro' in services['joe-board-pusher']['volumes'], 'disabled stager removed read-only mount')
        print('ops408_v1_runtime=2eb3953e-identical_except_build v2_images=r17 schema=v2 pusher_v2_mount=ro stager_v2_mount=rw disabled_stager=v2_fail_closed')
        require(actual['hostCompose']['services']['paper-desk-executor'] == actual['service'], 'host executor service mismatch')
        print('hsb0_v1_runtime_equality=image,options,service,units,firewall,users,executor_source_drvPaths,compose_except_build sha256=' + hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest())


def selector_regressions():
    # Evaluate the actual csb0 declaration with isolated release JSON fixtures.
    # No flake mutation, daemon access or NixOS build is needed.
    module_path = ROOT / 'tests/T76-joe-slash-routing.py'
    spec = importlib.util.spec_from_file_location('joe_routing', module_path)
    routing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(routing)
    release = check()
    update = 'update = a: b: a // builtins.mapAttrs (n: v: if builtins.hasAttr n a && builtins.isAttrs a.${n} && builtins.isAttrs v then update a.${n} v else v) b;'
    for selected in ('current', 'previous', 'v2'):
        fixture = copy.deepcopy(release)
        fixture['active'] = selected
        active = fixture['sets'][selected]
        if selected == 'v2':
            # Synthetic downstream pins exercise evaluation; never producer sign-off.
            active['board']['image'] = 'csb0-joe-board:source-' + active['board']['rev']
            for name in ('pusher', 'executor'):
                active[name] = copy.deepcopy(fixture['sets']['current'][name])
        with tempfile.TemporaryDirectory(prefix='ops354-selector-') as folder:
            folder = pathlib.Path(folder).resolve()
            release_path = folder / 'release.json'
            release_path.write_text(json.dumps(fixture))
            config = (ROOT / 'hosts/csb0/configuration.nix').read_text()
            config = config.replace('./joedesk-release.json', str(release_path))
            config = config.replace('import ./docker/compose-spec.nix', 'import ' + str(ROOT / 'hosts/csb0/docker/compose-spec.nix'))
            module = folder / 'configuration.nix'
            module.write_text(config)
            args = '''{ lib.recursiveUpdate = update; pkgs = {}; config = {}; inputs.joedesk = { outPath = "/nix/store/joedesk-selector-fixture"; rev = "''' + active['board']['rev'] + '''"; }; }'''
            expr = 'let ' + update + ' in (import ' + str(module) + ' ' + args + ').nixcfg.composeStack.spec.services.joe-board'
            service = json.loads(subprocess.check_output(['nix', 'eval', '--impure', '--json', '--expr', expr], cwd=ROOT))
            contract = {'service': service, 'excludeFromPull': ['joe-board']}
            # Only the Dockerfile I/O is stubbed: image, policy and immutable-path
            # assertions run unchanged against the real evaluated host declaration.
            with patch.object(pathlib.Path, 'is_file', return_value=True):
                routing.verify_pinned_build(contract, fixture, active['board']['rev'])
                broken = copy.deepcopy(contract)
                broken['service']['pull_policy'] = 'build'
                try:
                    routing.verify_pinned_build(broken, fixture, active['board']['rev'])
                except routing.ContractError:
                    pass
                else:
                    raise AssertionError('incorrect release policy passed')
                broken = copy.deepcopy(contract)
                broken['service']['image'] = 'wrong-image'
                try:
                    routing.verify_pinned_build(broken, fixture, active['board']['rev'])
                except routing.ContractError:
                    pass
                else:
                    raise AssertionError('incorrect release image passed')
    probes = []
    def fake_request(opener, url, method='GET', extra_headers=None):
        probes.append((url, method, extra_headers or {}))
        if '/joe?' in url or url.endswith('/joe'):
            return 301, {'Location': url.replace('/joe', '/joe/', 1)}
        return 302, {'Location': '/oauth2/start'}
    with patch.object(routing, 'request_without_redirects', side_effect=fake_request):
        routing.verify_live('v1')
    for route in ('/joe/', '/joe/data.json', '/joe/history.json', '/joe/joe.css'):
        require(any(url.endswith(route) and not headers for url, _, headers in probes), 'missing v1 anonymous live probe')
        require(any(url.endswith(route) and 'X_Auth_Request_User' in headers and 'X.Auth.Request.User' in headers and 'X-Forwarded_User' in headers for url, _, headers in probes), 'missing alias live negative probe')
    require(not any('/healthz' in url for url, _, _ in probes), 'v1 must not require public v2 health')
    for schema in ('v1', 'v2'):
        fixture = copy.deepcopy(release)
        fixture['sets'][fixture['active']]['board']['data_schema'] = schema
        argv = ['T76', '--labels-only', '--live'] + (['--joedesk-source', '/fixture'] if schema == 'v2' else [])
        with patch.object(routing, 'RELEASE_SET') as path_mock, \
             patch.object(routing.sys, 'argv', argv), \
             patch.object(routing, 'load_joe_labels', return_value={}), \
             patch.object(routing, 'verify_rendered_contract'), \
             patch.object(routing, 'verify_live') as live, \
             patch.object(routing, 'verify_release_smoke') as delegate, \
             patch('builtins.print'):
            path_mock.read_text.return_value = json.dumps(fixture)
            routing.main()
            live.assert_called_once_with(schema)
            require(delegate.call_count == (1 if schema == 'v2' else 0), 'live delegate must follow active schema')
    workflow = (ROOT / '.github/workflows/check.yml').read_text()
    for name in ('T100-joedesk-release.py', 'T101-joedesk-operations.mjs', 'T102-joedesk-host-gate.mjs'):
        require(name in workflow, 'JoeDesk regression test missing from CI: ' + name)
    print('release_selector_fixtures=current,previous,v2 live_mode_fixtures=v1,v2 alias_negatives=ok')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--joedesk-source', type=pathlib.Path)
    parser.add_argument('--prove-current', action='store_true', help='pre-cutover byte equality against baseline HEAD')
    args = parser.parse_args()
    check(args.joedesk_source)
    variant_b_regressions()
    selector_regressions()
    if args.prove_current:
        evaluation_proof()
    print('joedesk_release_set=ok')
