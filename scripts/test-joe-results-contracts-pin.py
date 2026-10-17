#!/usr/bin/env python3
"""JOED-20: recreate the complete contracts closure from its immutable source."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'modules/joe-results-producer'


def recreate(source, lock):
    """Copy the source closure, then verify set, digests and every byte."""
    with tempfile.TemporaryDirectory(prefix='joed20-recreate-') as temporary:
        rebuilt = Path(temporary)
        shutil.copytree(source / 'contracts', rebuilt / 'contracts', symlinks=True)
        shutil.copyfile(MODULE / 'contracts.lock.json', rebuilt / 'contracts.lock.json')
        # Same independently pinned checker as build/startup, against the copy.
        checker = (MODULE / 'verify-contracts.mjs').as_uri()
        subprocess.run(['node', '--input-type=module', '-e',
                        f'import {{ verifyContracts }} from {json.dumps(checker)}; '
                        f'verifyContracts({json.dumps(str(rebuilt))});'], check=True, capture_output=True, text=True)
        entries = []
        for name, expected in sorted(lock['files'].items()):
            actual = (rebuilt / 'contracts' / name).read_bytes()
            assert actual == (MODULE / 'contracts' / name).read_bytes(), 'contract bytes differ'
            digest = hashlib.sha256(actual).hexdigest()
            assert len(actual) == expected['bytes'] and digest == expected['sha256'], 'file digest differs'
            entries.append(dict(path=f'contracts/{name}', size=len(actual), sha256=digest))
        digest = hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest()
        assert digest == lock['contract_set_sha256'], 'set digest differs'
        print(f"PASS recreate-from-pin: {len(entries)} files byte-identical; per-file and set digests verified; revision={lock['revision']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument('--offline', action='store_true', help='explicit local skip; forbidden in GitHub Actions')
    inputs.add_argument('--source', type=Path, help='local clean checkout at the exact pin (local proof only)')
    args = parser.parse_args()
    ci = os.environ.get('GITHUB_ACTIONS') == 'true'
    if ci and (args.offline or args.source):
        raise SystemExit('FAIL: CI requires the pinned private-source fetch')
    subprocess.run(['node', str(MODULE / 'verify-contracts.mjs')], check=True)
    lock = json.loads((MODULE / 'contracts.lock.json').read_text())
    if args.offline:
        print('SKIP recreate-from-pin: explicitly offline; immutable private source was not fetched')
        return
    if args.source:
        source = args.source.resolve()
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        assert revision == lock['revision'], 'local checkout revision differs from contracts pin'
        subprocess.run(['git', '-C', str(source), 'diff', '--quiet', 'HEAD', '--', 'contracts'], check=True)
    else:
        # Same private GitHub transport as T76 and OPS-354's test-joedesk-ci.py.
        # Do not print fetch stderr: authentication diagnostics may be sensitive.
        owner, repo = lock['repository'].removeprefix('https://github.com/').split('/')
        expr = '(builtins.fetchTree { type = "github"; owner = ' + json.dumps(owner) + '; repo = ' + json.dumps(repo) + '; rev = ' + json.dumps(lock['revision']) + '; }).outPath'
        try:
            result = subprocess.run(['nix', 'eval', '--impure', '--json', '--expr', expr],
                                    cwd=ROOT, capture_output=True, text=True, timeout=120)
            source = Path(json.loads(result.stdout)) if result.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            source = None
        if source is None:
            message = 'recreate-from-pin: immutable source unavailable via Nix GitHub transport (private access, network or Nix unavailable)'
            if ci:
                raise SystemExit('FAIL ' + message)
            print('SKIP ' + message)
            return
    recreate(source, lock)


if __name__ == '__main__':
    main()
