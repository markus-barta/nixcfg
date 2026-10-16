#!/usr/bin/env python3
"""OPS-354 release-set consistency and evaluation-only refactor proof."""
import argparse
import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = ROOT / 'hosts/csb0/joedesk-release.json'
BASELINE = 'ed5e43d6600b6b610a8c4483eba2627f00b4fd58'
LEGACY = 'db621bf7f00a4c609b0930ef7d5020f3c8935ee9'
SHA = re.compile(r'[0-9a-f]{64}')
REV = re.compile(r'[0-9a-f]{40}')


def require(value, reason):
    if not value:
        raise AssertionError(reason)


def check(source=None):
    release = json.loads(RELEASE.read_text())
    require(release['schema'] == 'nixcfg.joedesk-release-set.v1', 'release set schema')
    require(set(release['sets']) == {'current', 'v2', 'previous'}, 'three explicit release sets')
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
            require(board['version_scheme'] == 'inspr-calver-3' and re.fullmatch(r'\d{12}\.0\.0', board['version']), 'candidate canonical CalVer3')
            contracts = item['contracts']
            digest = contracts['contract_set_sha256']
            require(SHA.fullmatch(digest), 'contract digest malformed')
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
        expected = json.loads((source / 'release/contracts.json').read_text())
        require(release['sets']['v2']['contracts'] == expected, 'candidate differs from authoritative contracts.json')
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        require(release['sets']['v2']['board']['rev'] == revision, 'candidate revision mismatch')
    return release


def evaluation_proof():
    # Compare the release refactor with the recorded baseline declarations against the SAME
    # compose spec. Item 1's intentional routing change is outside this proof.
    # Stubs affect only external source/service paths, identically on both sides.
    update = 'update = a: b: a // builtins.mapAttrs (n: v: if builtins.hasAttr n a && builtins.isAttrs a.${n} && builtins.isAttrs v then update a.${n} v else v) b;'
    args = '''{ lib = { recursiveUpdate = update; cleanSourceWith = _: "/nix/store/pusher-stand-in"; mkOption = x: x; }; pkgs = {}; config.nixcfg = { paperDeskExecutor.serviceSpec = {}; agentMailbox.serviceSpec = {}; }; inputs.joedesk = { outPath = "/nix/store/joedesk-stand-in"; rev = "''' + LEGACY + '''"; }; }'''
    for relative in ('hosts/csb0/configuration.nix', 'hosts/hsb0/configuration.nix'):
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
    old_executor = subprocess.check_output(['git', 'show', BASELINE + ':modules/paper-desk-executor/default.nix'], cwd=ROOT, text=True)
    old_image = re.search(r'image = lib.mkOption \{.*?default = "([^"]+)";', old_executor, re.S)[1]
    current = check()['sets']['current']
    actual_image = subprocess.check_output(['nix', 'eval', '--impure', '--raw', '--expr', '(import ' + str(ROOT / 'modules/paper-desk-executor/default.nix') + ' { config = {}; pkgs = {}; lib.mkOption = x: x; }).options.nixcfg.paperDeskExecutor.image.default'], cwd=ROOT, text=True)
    require(current['executor']['image'] == old_image == actual_image, 'executor default changed')
    for name in ('pusher', 'executor'):
        pin = current[name]
        tree = subprocess.check_output(['git', 'rev-parse', pin['nixcfg_rev'] + ':' + pin['source_path']], cwd=ROOT, text=True).strip()
        require(tree == pin['source_tree'], 'recorded source tree mismatch')
    print('release_refactor=byte-identical-static-specs executor_default=unchanged linux_drvPath=pending')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--joedesk-source', type=pathlib.Path)
    parser.add_argument('--prove-current', action='store_true', help='pre-cutover byte equality against baseline HEAD')
    args = parser.parse_args()
    check(args.joedesk_source)
    if args.prove_current:
        evaluation_proof()
    print('joedesk_release_set=ok')
