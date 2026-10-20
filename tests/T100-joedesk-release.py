#!/usr/bin/env python3
"""OPS-354 release-set consistency and evaluation-only refactor proof."""
import argparse
import json
import hashlib
import pathlib
import re
import subprocess
import tempfile
import copy
import importlib.util
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = ROOT / 'hosts/csb0/joedesk-release.json'
BASELINE = 'ed5e43d6600b6b610a8c4483eba2627f00b4fd58'
# OPS updates the recorded source revision to the exact main merge of #1058.
# Until then the equality proof deliberately compares against the older main.
HSB0_BASELINE = json.loads(RELEASE.read_text())['sets']['current']['executor']['nixcfg_rev']
HSB0_IMAGE = 'hsb0-joe-board-pusher:household-v2-switch-set-r14-202610201330'
LEGACY = 'db621bf7f00a4c609b0930ef7d5020f3c8935ee9'
PUBLISHED = 'd36b5295295a6901e36fdf2dc0d64353ddf88d0e'
PUBLISHED_TREE = 'ba066aaeebf193eab93154ca9e0335f7dbba9d28'
CONTRACT_SET_SHA256 = '000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5'
CONTRACTS_JSON_SHA256 = '5c20c38be4602f6c142ece1c1abc65172306d504aa0a74d098e10bb15f78ef17'
SHA = re.compile(r'[0-9a-f]{64}')
REV = re.compile(r'[0-9a-f]{40}')


def require(value, reason):
    if not value:
        raise AssertionError(reason)


def check(source=None):
    release = json.loads(RELEASE.read_text())
    require(release['schema'] == 'nixcfg.joedesk-release-set.v1', 'release set schema')
    require(set(release['sets']) == {'current', 'v2', 'previous'}, 'three explicit release sets')
    for name in ('pusher', 'executor'):
        require(release['sets']['current'][name]['image'] == HSB0_IMAGE, name + ': current image must be the r14 switch set')
    stage_image = re.search(r'services\.joe-household-v2-stage = \{.*?image = "([^"]+)";', (ROOT / 'hosts/hsb0/configuration.nix').read_text(), re.S)[1]
    require(stage_image == HSB0_IMAGE, 'stage image must be the r14 switch set')
    fixture_image = re.search(r'joe-board-pusher\.image = "([^"]+)";', (ROOT / 'tests/paper-desk-executor-eval.nix').read_text())[1]
    require(fixture_image == HSB0_IMAGE, 'executor eval fixture must use the r14 switch set')
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
            require(board['version_scheme'] == 'inspr-calver-3' and board['version'] == '261019102825.0.0' and board['release_sequence'] == 25, 'published canonical CalVer3 metadata mismatch')
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
    require(current['executor']['image'] == actual_image == HSB0_IMAGE, 'executor default must use the r14 switch set')
    for name in ('pusher', 'executor'):
        pin = current[name]
        tree = subprocess.check_output(['git', 'rev-parse', pin['nixcfg_rev'] + ':' + pin['source_path']], cwd=ROOT, text=True).strip()
        require(tree == pin['source_tree'], 'recorded source tree mismatch')
    # Compare hsb0 with the recorded exact main, including its stage and local
    # mailbox. OPS advances this pin after merging #1058 into main.
    hsb0_evaluation_proof()
    print('release_refactor=byte-identical-static-specs executor_default=r14-main-equal linux_toplevel_drvPath=pending')


def hsb0_evaluation_proof():
    # Reuse the real module evaluator with real Linux packages in a disposable
    # local store. This only evaluates derivations; it never builds or contacts
    # the daemon, network or any host. Source drvPaths bind the closure bytes.
    harness = (ROOT / 'tests/paper-desk-executor-eval.nix').read_text()
    baseline_executor = subprocess.check_output(['git', 'show', HSB0_BASELINE + ':modules/paper-desk-executor/default.nix'], cwd=ROOT, text=True)
    baseline_image = re.search(r'image = lib.mkOption \{.*?default = "([^"]+)";', baseline_executor, re.S)[1]
    start = harness.index('    specialArgs.pkgs = {')
    end = harness.index('    modules = [', start)
    harness = harness[:start] + '    specialArgs.pkgs = import <nixpkgs> { system = "x86_64-linux"; };\n' + harness[end:]
    harness = harness.replace(
        'extraRestartTriggers = lib.mkOption { type = lib.types.listOf lib.types.str; };',
        'extraRestartTriggers = lib.mkOption { type = lib.types.listOf lib.types.anything; };')
    harness = harness[:harness.index('if tailnetContract then\n')] + '''{
      image = cfg.nixcfg.paperDeskExecutor.image;
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
        folder = pathlib.Path(folder)
        main = folder / 'main'
        main.mkdir()
        paths = ['modules/paper-desk-executor', 'modules/tailnet-peers',
                 'modules/agent-mailbox', 'modules/joe-results-producer',
                 'modules/ib-gateway-session', 'hosts/hsb0/configuration.nix',
                 'hosts/hsb0/docker/compose-spec.nix', 'hosts/hsb0/docker/joe-board-pusher']
        archive = subprocess.check_output(['git', 'archive', HSB0_BASELINE, *paths], cwd=ROOT)
        subprocess.run(['tar', '-xf', '-', '-C', str(main)], input=archive, check=True)
        values = []
        for name, source in (('main', main), ('merged', ROOT)):
            expression = folder / (name + '.nix')
            source_harness = harness
            if name == 'main':
                # Give each side its own real runtime in the module assertion;
                # the complete evaluated results must still compare equal.
                source_harness = source_harness.replace('joe-board-pusher.image = "' + HSB0_IMAGE + '";', 'joe-board-pusher.image = "' + baseline_image + '";')
            expression.write_text(source_harness.replace('../modules/', str(source / 'modules') + '/').replace('@ROOT@', str(source)))
            values.append(subprocess.check_output([
                'nix', 'eval', '--offline', '--store', str(folder / 'store'), '--impure',
                '--json', '--file', str(expression), '--apply', 'f: f {}'], cwd=ROOT))
        actual = json.loads(values[1])
        for name in ('joe-board-pusher', 'paper-desk-executor', 'joe-household-v2-stage'):
            require(actual['hostCompose']['services'][name]['image'] == HSB0_IMAGE, name + ': evaluated host image must be the r14 switch set')
        require(actual['image'] == HSB0_IMAGE, 'evaluated executor image must be the r14 switch set')
        require(values[0] == values[1], 'hsb0 differs from main: image, service, units, firewall, users, source derivations or compose')
        require(actual['hostCompose']['services']['paper-desk-executor'] == actual['service'], 'host executor service mismatch')
        print('hsb0_main_equality=image,service,units,firewall,users,source_drvPaths,compose sha256=' + hashlib.sha256(values[1]).hexdigest())


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
            folder = pathlib.Path(folder)
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
                broken['service']['pull_policy'] = 'build' if selected == 'previous' else 'never'
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
    selector_regressions()
    if args.prove_current:
        evaluation_proof()
    print('joedesk_release_set=ok')
