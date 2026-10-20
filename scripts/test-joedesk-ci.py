#!/usr/bin/env python3
"""OPS-354: run source-dependent CI checks using T76's Nix source transport."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ALLOWED = {'tests/T101-joedesk-operations.mjs', 'tests/T102-joedesk-host-gate.mjs'}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ALLOWED:
        raise SystemExit('use one exact JoeDesk CI test path')
    test = sys.argv[1]
    release = json.loads((ROOT / 'hosts/csb0/joedesk-release.json').read_text())
    revisions = sorted({item['board']['rev'] for item in release['sets'].values()})
    # Never print fetch stderr: it may contain authentication diagnostics.
    expr = '{ ' + ' '.join(json.dumps(rev) + ' = (builtins.fetchTree { type = "github"; owner = "markus-barta"; repo = "joedesk"; rev = ' + json.dumps(rev) + '; }).outPath;' for rev in revisions) + ' }'
    result = subprocess.run(['nix', 'eval', '--impure', '--json', '--expr', expr], cwd=ROOT, capture_output=True, text=True)
    sources = json.loads(result.stdout) if result.returncode == 0 else None
    if sources is None:
        print('::warning::JoeDesk immutable sources unavailable through T76 Nix GitHub transport (private repo access or fetch failed). T101 real offline/legacy/identity checks and T102 are SKIPPED, not passed.', flush=True)
        if test.endswith('T102-joedesk-host-gate.mjs'):
            print('joedesk_production_host_gate=skipped reason=immutable_sources_unavailable')
            return 0
    with tempfile.TemporaryDirectory(prefix='ops354-ci-') as folder:
        if test.endswith('T101-joedesk-operations.mjs'):
            test_env = dict(os.environ)
            # Do not inherit an unrelated checkout and misattribute its evidence.
            test_env.pop('JOEDESK_TEST_SOURCE', None)
            test_env.pop('JOEDESK_LEGACY_SOURCE', None)
            if sources:
                test_env['JOEDESK_TEST_SOURCE'] = sources[release['sets']['v2']['board']['rev']]
                test_env['JOEDESK_LEGACY_SOURCE'] = sources[release['sets']['previous']['board']['rev']]
            return subprocess.run(['node', '--test', test], cwd=ROOT, env=test_env).returncode
        source_map = pathlib.Path(folder) / 'sources.json'
        source_map.write_text(json.dumps(sources))
        return subprocess.run(['node', test, '--source-map', str(source_map)], cwd=ROOT).returncode


if __name__ == '__main__':
    raise SystemExit(main())
