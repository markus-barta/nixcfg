#!/usr/bin/env bash
# OPS-207: offline declaration/proxy/CI contract; full merged config checked in CI.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

for source in flake.nix hosts/hsb0/configuration.nix hosts/hsb0/docker/compose-spec.nix modules/pharos-guarded-deploy/default.nix tests/hausnetz-hsb0-eval.nix; do
  nix-instantiate --parse "$source" >/dev/null
done

# Evaluate the actual host declarations and compose service without fetching
# inputs or realizing derivations. Only mkBefore needs a value-free stub.
nix-instantiate --eval --strict --json --expr '
  let
    host = import ./hosts/hsb0/configuration.nix {
      pkgs = {}; config = {}; inputs = {};
      lib.mkBefore = x: x;
    };
    compose = import ./hosts/hsb0/docker/compose-spec.nix;
  in {
    service = host.services.hausnetz;
    limits = host.systemd.services.hausnetz.serviceConfig;
    firewall = host.networking.firewall;
    ssh = host.programs.ssh;
    proxySource = toString host.environment.etc."hsb0-home-hausnetz.conf".source;
    home = compose.services.hsb0-home;
  }
' | python3 -c '
import json, sys
c = json.load(sys.stdin)
s, fw, home = c["service"], c["firewall"], c["home"]
assert s["enable"] and s["listen"] == "0.0.0.0:8377"
assert s["firewallInterfaces"] == ["br-+", "docker0"]
assert s["discovery"] == {"openFirewallMdns": True, "mdnsInterfaces": ["enp2s0f0"]}
assert "seed" not in s and "leasesFile" not in s["discovery"] and "extraArgs" not in s
assert fw["enable"] and 8377 not in fw["allowedTCPPorts"] and 5353 not in fw["allowedUDPPorts"]
assert c["limits"] == {"MemoryMax": "512M", "CPUQuota": "50%", "Nice": 10}
assert home.get("network_mode", "bridge") == "bridge"
assert home["extra_hosts"] == ["host.docker.internal:host-gateway"]
assert "/etc/hsb0-home-hausnetz.conf:/etc/nginx/hostdash-extra/hausnetz.conf:ro" in home["volumes"]
assert c["proxySource"].endswith("/hosts/hsb0/docker/hsb0-home-hausnetz.conf")
ssh = c["ssh"]
assert "Match host github.com localuser root" in ssh["extraConfig"]
assert "IdentityFile /root/.ssh/hausnetz_deploy" in ssh["extraConfig"]
assert "IdentitiesOnly yes" in ssh["extraConfig"]
assert ssh["extraConfig"].strip().endswith("Host *")
assert ssh["knownHosts"]["github.com"]["publicKey"] == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
print("OPS-207 evaluated host declarations: OK")
'

python3 - <<'PY'
import json
import re
import os
import stat
import subprocess
import tempfile
from pathlib import Path

defaults = json.loads(subprocess.check_output(['nix-instantiate', '--eval', '--strict', '--json', '--expr', '''
  let
    module = host: import ./modules/pharos-guarded-deploy/default.nix {
      config.networking.hostName = host; lib.mkOption = x: x; inputs = {}; pkgs = {};
    };
    defaults = host: let opts = (module host).options.inspr.pharosGuardedDeploy; in {
      privateInputHosts = opts.privateInputHosts.default;
      canEvaluatePrivateInputs = opts.canEvaluatePrivateInputs.default;
    };
  in { hsb0 = defaults "hsb0"; hsb8 = defaults "hsb8"; }
'''], text=True))
assert defaults == {'hsb0': {'privateInputHosts': ['hsb0'], 'canEvaluatePrivateInputs': True},
                    'hsb8': {'privateInputHosts': ['hsb0'], 'canEvaluatePrivateInputs': False}}

proxy = Path('hosts/hsb0/docker/hsb0-home-hausnetz.conf').read_text()
redirect = re.search(r'location = /ops\s*\{([^}]+)\}', proxy)[1]
app = re.search(r'location /ops/\s*\{([^}]+)\}', proxy)[1]
for location in (redirect, app):
    assert re.search(r'allow 192\.168\.1\.0/24;\s*deny all;', location)
# A rewrite-phase return bypasses access checks, so redirect after try_files.
assert not re.search(r'^\s*return\s', redirect, re.M)
assert 'try_files "" @hausnetz_ops_redirect;' in redirect
assert re.search(r'location @hausnetz_ops_redirect\s*\{\s*absolute_redirect off;\s*return 301 /ops/;', proxy)
assert 'client_max_body_size 13m;' in app
assert 'proxy_hide_header Cache-Control;' in app
assert 'add_header Cache-Control "no-store" always;' in app
for directive in ('proxy_pass http://host.docker.internal:8377/;', 'proxy_buffering off;',
                  'proxy_http_version 1.1;', 'proxy_set_header Connection "";',
                  'proxy_read_timeout 1h;', 'proxy_cache off;'):
    assert directive in proxy, directive
assert 'include /etc/nginx/hostdash-extra/*.conf;' in Path('modules/files/hostdash-nginx.conf').read_text()

pin = '1f876f1d28d74d5931f4f3628a90de112a43506c'
assert f'git+ssh://git@github.com/markus-barta/hausnetz?rev={pin}' in Path('flake.nix').read_text()
lock = json.loads(Path('flake.lock').read_text())
assert lock['nodes'][lock['root']]['inputs']['hausnetz'] == 'hausnetz'
node = lock['nodes']['hausnetz']
assert node['inputs'] == {'nixpkgs': ['nixpkgs']}
for source in ('locked', 'original'):
    assert node[source]['type'] == 'git' and node[source]['rev'] == pin
    assert node[source]['url'] == 'ssh://git@github.com/markus-barta/hausnetz'
assert node['locked']['narHash'] == 'sha256-BZyTWNxApPN/K44Bbhub7TNfsziEYLPXaqmizfQ6emM='
imports = [p for p in Path('hosts').rglob('*.nix') if 'inputs.hausnetz.nixosModules.default' in p.read_text()]
assert imports == [Path('hosts/hsb0/configuration.nix')], imports

workflows = ('check', 'pharos-system-update', 'pharos-host-removal', 'pharos-host-settings', 'update-flake-lock', 'pharos-release-rollout')
for name in workflows:
    text = Path(f'.github/workflows/{name}.yml').read_text()
    assert 'GIT_CONFIG_' not in text, name
    assert 'HAUSNETZ_DEPLOY_KEY' not in text.split('jobs:', 1)[0], name
    uses = list(re.finditer(r'uses: \./\.github/actions/hausnetz-input\n\s+with:\n\s+deploy-key: \$\{\{ secrets\.HAUSNETZ_DEPLOY_KEY \}\}', text))
    assert len(uses) == (2 if name == 'check' else 0 if name in ('update-flake-lock', 'pharos-release-rollout') else 1), name
    assert text.count('secrets.HAUSNETZ_DEPLOY_KEY') == len(uses), name
    if name == 'check':
        jobs = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', text.split('jobs:', 1)[1], re.M | re.S))
        assert 'GH_TOKEN_FOR_UPDATES' not in text
        assert "if: matrix.host == 'hsb0'\n        uses: ./.github/actions/hausnetz-input" in jobs['check']
        assert "if: steps.pin.outputs.pin_only != 'true'\n        uses: ./.github/actions/hausnetz-input" in jobs['pharos-rollout']
        assert all('hausnetz-input' not in job for name, job in jobs.items() if name not in ('check', 'pharos-rollout'))
    if name == 'pharos-host-settings':
        assert "if: inputs.host == 'hsb0'\n        uses: ./.github/actions/hausnetz-input" in text

# Execute the real composite action script with a non-secret fixture. No SSH
# connection is made; prove file modes, host pinning and absence from logs/env.
action = Path('.github/actions/hausnetz-input/action.yml').read_text()
script = '\n'.join(line[8:] for line in action.split('      run: |\n', 1)[1].splitlines())
assert 'HAUSNETZ_DEPLOY_KEY: ${{ inputs.deploy-key }}' in action
assert 'ssh-keyscan ' not in script
with tempfile.TemporaryDirectory(prefix='ops207-ci-') as tmp:
    output = Path(tmp, 'github-output')
    fixture_key = 'OPS-207 non-secret deploy-key fixture'
    child_env = dict(os.environ, RUNNER_TEMP=tmp, GITHUB_ENV=str(output), HAUSNETZ_DEPLOY_KEY=fixture_key)
    result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert fixture_key not in result.stdout + result.stderr + output.read_text()
    ssh_dir, = Path(tmp).glob('hausnetz-ssh.*')
    assert stat.S_IMODE(ssh_dir.stat().st_mode) == 0o700
    assert stat.S_IMODE((ssh_dir / 'key').stat().st_mode) == 0o600
    assert (ssh_dir / 'key').read_text() == fixture_key + '\n'
    assert (ssh_dir / 'known_hosts').read_text() == 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n'
    assert all(option in output.read_text() for option in ('-F /dev/null', 'IdentitiesOnly=yes', 'BatchMode=yes', 'UserKnownHostsFile=', 'GlobalKnownHostsFile=/dev/null', 'StrictHostKeyChecking=yes'))
    child_env['HAUSNETZ_DEPLOY_KEY'] = ''
    result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
    assert result.returncode != 0 and 'HAUSNETZ_DEPLOY_KEY is required' in result.stderr

# Run the declared warmer against a fake Nix. Fail hsb0 while allowing later
# hosts to warm, and prove that a dry-run failure cannot look already cached.
warmer = subprocess.check_output(['nix-instantiate', '--eval', '--strict', '--json', '--expr', '''
  (import ./hosts/hsb0/configuration.nix {
    pkgs = {}; config = {}; inputs = {}; lib.mkBefore = x: x;
  }).systemd.services.ncps-warmer.script
'''], text=True)
warmer = json.loads(warmer)
with tempfile.TemporaryDirectory(prefix='ops207-warmer-') as tmp:
    root = Path(tmp)
    (root / 'git').write_text('#!/usr/bin/env bash\nexit 0\n')
    (root / 'nix').write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$WARMER_CALLS"
if [[ "$*" == *nixosConfigurations.hsb0* && "$FAIL_HSB0" == 1 ]]; then
  echo 'fixture: private input unavailable' >&2
  exit 1
fi
if [[ "$WARMER_FETCH" == 1 ]]; then
  printf 'these paths will be fetched:\\n  /nix/store/fixture-substitute\\n' >&2
fi
''')
    (root / 'nix-store').write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$WARMER_REALISED"
''')
    for command in ('git', 'nix', 'nix-store'):
        (root / command).chmod(0o700)
    # Preserve the real declared script, replacing only its checkout directory.
    script = warmer.replace('REPO="/home/mba/Code/nixcfg"', f'REPO="{root}"')
    child_env = dict(os.environ, PATH=f'{root}:' + os.environ['PATH'], WARMER_CALLS=str(root / 'calls'), WARMER_REALISED=str(root / 'realised'))
    for fail, fetch in (('1', '0'), ('0', '0'), ('0', '1')):
        child_env.update(FAIL_HSB0=fail, WARMER_FETCH=fetch)
        result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
        if fail == '1':
            assert result.returncode != 0
            assert 'warmer: hsb0 — evaluation/dry-run FAILED' in result.stderr
            assert 'warmer: hsb0 — nothing to fetch' not in result.stdout
            assert 'warmer: mbp2607' in result.stdout and 'warmer: done' not in result.stdout
        else:
            assert result.returncode == 0, result.stderr
            assert 'warmer: done' in result.stdout
            assert ('warmer: hsb0 — warmed 1 paths' if fetch == '1' else 'warmer: hsb0 — nothing to fetch (already cached)') in result.stdout, result.stdout
    assert '/nix/store/fixture-substitute' in (root / 'realised').read_text()

# Run the selection expression from each real update path against a lock fixture.
fixture = {"root": "root", "nodes": {"root": {"inputs": {"nixpkgs": "nixpkgs", "hausnetz": "hausnetz", "home-manager": "hm", "alias": ["nixpkgs"]}}}}
for path in ('.github/workflows/update-flake-lock.yml', 'scripts/prepare-pharos-system-update.sh'):
    text = Path(path).read_text()
    expression = re.search(r"jq -r '([^']+)' flake.lock", text)[1]
    selection = subprocess.check_output(['jq', '-r', expression], input=json.dumps(fixture).encode()).decode().split()
    assert selection == ['home-manager', 'nixpkgs'], (path, selection)
assert 'inputs: ${{ steps.inputs.outputs.inputs }}' in Path('.github/workflows/update-flake-lock.yml').read_text()
assert 'nix flake update "${update_inputs[@]}"' in Path('scripts/prepare-pharos-system-update.sh').read_text()
ci = Path('.github/workflows/check.yml').read_text()
assert 'bash tests/T99-hausnetz-hsb0.sh' in ci and 'import ./tests/hausnetz-hsb0-eval.nix' in ci
step = ci.split('      - name: Verify hausnetz in the full hsb0 configuration (OPS-207)\n', 1)[1].split('  # ===', 1)[0]
command = '\n'.join(line[10:] for line in step.split('        run: |\n', 1)[1].splitlines() if line.strip())
assert command in Path('hosts/hsb0/docs/RUNBOOK.md').read_text(), 'runbook must carry the exact CI command'
print('OPS-207 proxy and CI contracts: OK')
PY
